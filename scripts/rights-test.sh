#!/usr/bin/env bash
# Proves what a pipeline identity may NOT do (spec section 7, "Rechte-Test"), with one control per identity that
# must still work, so the test cannot pass because everything is refused.
# Usage (signed in as the identity under test): bash scripts/rights-test.sh <plan|staging>
# Env: TF_STATE_SA
set -euo pipefail
export MSYS_NO_PATHCONV=1
# shellcheck source=/dev/null
source "$(dirname "$0")/expect.sh"
who=${1:?plan or staging}
SA=${TF_STATE_SA:?}
SUB=$(az account show --query id -o tsv | tr -d '\r')
SELF=$(az account get-access-token --query accessToken -o tsv | tr -d '\r' | python3 -c '
import base64, json, sys
p = sys.stdin.read().split(".")[1]; p += "=" * (-len(p) % 4)
print(json.loads(base64.urlsafe_b64decode(p))["oid"])')
STAGING_RG_ID="/subscriptions/${SUB}/resourceGroups/rg-swiftjob-staging"
grant_self() { # role scope
  az role assignment create --assignee-object-id "$SELF" --assignee-principal-type ServicePrincipal --role "$1" --scope "$2" -o none
}
grant_and_remove_allowed() {
  grant_self "Monitoring Metrics Publisher" "$STAGING_RG_ID"
  az role assignment delete --assignee "$SELF" --role "Monitoring Metrics Publisher" --scope "$STAGING_RG_ID" -o none
}

case "$who" in
  plan)
    expect_refused "create a resource group" "AuthorizationFailed" \
      az group create -n rg-swiftjob-rights-test -l germanywestcentral --tags project=swiftjob env=test owner=steven -o none || true
    expect_refused "write to the platform state container" "AuthorizationPermissionMismatch|AuthorizationFailure" \
      az storage blob upload --account-name "$SA" -c platform -n rights-test.txt --data x --overwrite --auth-mode login -o none || true
    expect_refused "grant itself Owner on the subscription" "AuthorizationFailed" \
      grant_self Owner "/subscriptions/${SUB}" || true
    expect_ok "read the platform state container" \
      az storage blob list --account-name "$SA" -c platform --auth-mode login --num-results 1 -o none || true
    ;;
  staging)
    expect_refused "change the production resource group" "AuthorizationFailed" \
      az group update -n rg-swiftjob-prod --set tags.rightstest=1 -o none || true
    expect_refused "change the platform resource group" "AuthorizationFailed" \
      az group update -n rg-swiftjob-platform --set tags.rightstest=1 -o none || true
    expect_refused "grant itself Owner on staging" "AuthorizationFailed|does not have authorization" \
      grant_self Owner "$STAGING_RG_ID" || true
    expect_refused "grant itself Contributor on the subscription" "AuthorizationFailed|does not have authorization" \
      grant_self Contributor "/subscriptions/${SUB}" || true
    expect_refused "write to the platform state container" "AuthorizationPermissionMismatch|AuthorizationFailure" \
      az storage blob upload --account-name "$SA" -c platform -n rights-test.txt --data x --overwrite --auth-mode login -o none || true
    expect_ok "grant and remove an allowed role for a service principal" grant_and_remove_allowed || true
    ;;
  *) echo "usage: rights-test.sh <plan|staging>" >&2; exit 2 ;;
esac
expect_summary
