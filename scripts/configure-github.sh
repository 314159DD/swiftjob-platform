#!/usr/bin/env bash
# Repository settings as code: variables, environments with reviewers and branch rules, branch protection.
# Usage: GH_TOKEN=$(gh auth token --user 314159DD) bash scripts/configure-github.sh /tmp/bootstrap.out
# Secrets (BUDGET_ALERT_EMAIL, LEAK_BLOCKLIST) are set by hand with `gh secret set`, never from a file.
set -euo pipefail
REPO=${GITHUB_REPO:-314159DD/swiftjob-platform}
VALUES=${1:?path to the bootstrap output}
val() { grep "^$1=" "$VALUES" | cut -d= -f2; }

for key in AZURE_TENANT_ID AZURE_SUBSCRIPTION_ID TF_STATE_RG TF_STATE_SA AZURE_CLIENT_ID_PLAN AZURE_CLIENT_ID_PLATFORM AZURE_CLIENT_ID_POLICY_TEST PIPELINE_PRINCIPAL_IDS; do
  if [[ -z "$(val "$key" || true)" ]]; then echo "Missing or empty value for $key in $VALUES" >&2; exit 1; fi
done

# PIPELINE_PRINCIPAL_IDS (space-separated service principal object IDs of the three pipeline identities) is read by
# the RBAC guard in the Drift workflow.
for key in AZURE_TENANT_ID AZURE_SUBSCRIPTION_ID TF_STATE_RG TF_STATE_SA PIPELINE_PRINCIPAL_IDS; do
  gh variable set "$key" -R "$REPO" --body "$(val "$key")"
done

if [[ "$(gh api "repos/$REPO" --jq .private)" == "true" ]]; then
  echo "Repository is private: GitHub Free has no environments or branch protection for private repositories. Run this script again after the repository is public."
  exit 0
fi

REVIEWER_ID=$(gh api users/314159DD --jq .id)

# plan: every pull request, no reviewer, identity read-only on Azure resources; writes only the state lock
gh api -X PUT "repos/$REPO/environments/plan" --input - <<< '{"deployment_branch_policy": null}' > /dev/null
gh variable set AZURE_CLIENT_ID -R "$REPO" --env plan --body "$(val AZURE_CLIENT_ID_PLAN)"

# platform: only main, one required reviewer
gh api -X PUT "repos/$REPO/environments/platform" --input - > /dev/null <<EOF
{"reviewers": [{"type": "User", "id": ${REVIEWER_ID}}],
 "deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}}
EOF
if [[ -z "$(gh api "repos/$REPO/environments/platform/deployment-branch-policies" --jq '.branch_policies[] | select(.name == "main") | .name')" ]]; then
  gh api -X POST "repos/$REPO/environments/platform/deployment-branch-policies" -f name=main -f type=branch > /dev/null
fi
gh variable set AZURE_CLIENT_ID -R "$REPO" --env platform --body "$(val AZURE_CLIENT_ID_PLATFORM)"

# policy-test: only main, no reviewer (scheduled runs must not wait), identity that can validate the test templates
gh api -X PUT "repos/$REPO/environments/policy-test" --input - > /dev/null <<EOF
{"deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}}
EOF
if [[ -z "$(gh api "repos/$REPO/environments/policy-test/deployment-branch-policies" --jq '.branch_policies[] | select(.name == "main") | .name')" ]]; then
  gh api -X POST "repos/$REPO/environments/policy-test/deployment-branch-policies" -f name=main -f type=branch > /dev/null
fi
gh variable set AZURE_CLIENT_ID -R "$REPO" --env policy-test --body "$(val AZURE_CLIENT_ID_POLICY_TEST)"

# Not set here: the owner sets BUDGET_ALERT_EMAIL and LEAK_BLOCKLIST both as Actions secrets and as
# Dependabot secrets (`gh secret set NAME -R <repo> --app dependabot`), because Dependabot PRs do not
# receive Actions secrets.

# main: pull requests with green checks only, also for admins
gh api -X PUT "repos/$REPO/branches/main/protection" --input - > /dev/null <<'EOF'
{"required_status_checks": {"strict": true, "contexts": ["Terraform checks", "Script tests", "Leak check", "Plan"]},
 "enforce_admins": true,
 "required_pull_request_reviews": {"required_approving_review_count": 0},
 "restrictions": null,
 "allow_force_pushes": false,
 "allow_deletions": false}
EOF
echo "GitHub configured for $REPO"
