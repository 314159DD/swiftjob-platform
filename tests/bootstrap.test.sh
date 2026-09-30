#!/usr/bin/env bash
# Static checks for scripts/bootstrap.sh (it needs Azure, so it is not run here). `bash -n` cannot see ordering
# mistakes: a function called before it is defined aborts the real run.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
f="$root/scripts/bootstrap.sh"
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }
line() { grep -n -m1 -E "$1" "$f" | cut -d: -f1; }

bash -n "$f" && ok "bootstrap.sh parses" || bad "bootstrap.sh parses"

sr=$(line '^subject_repo\(\)'); fed=$(line '^federate\(\)'); idf=$(line '^identity\(\)')
subj=$(line '^SUBJECT_REPO=') csub=$(line '^CONFIG_SUBJECT_REPO=') first=$(line '^read -r PLAN_APP')
if (( sr < subj && fed < first && idf < first && subj < first && csub < first )); then
  ok "helpers and SUBJECT_REPO come before the first identity call"
else bad "helpers and SUBJECT_REPO come before the first identity call"; fi

stag=$(line '^read -r STAGING_APP'); cond=$(line '^APP_CONDITION=')
if (( stag < cond )); then ok "STAGING_SP is known before the ABAC condition is built"; else bad "STAGING_SP is known before the ABAC condition is built"; fi

cond_text=$(grep -E '^APP_CONDITION=' "$f")
if grep -q 'roleAssignments:PrincipalId\] ForAnyOfAllValues:GuidNotEquals {\${STAGING_SP}}' <<< "$cond_text"; then
  ok "the ABAC condition excludes tf-staging's own principal ID"
else bad "the ABAC condition excludes tf-staging's own principal ID"; fi
if grep -q "PrincipalType\] StringEqualsIgnoreCase 'ServicePrincipal'" <<< "$cond_text"; then
  ok "the ABAC condition limits grants to service principals"
else bad "the ABAC condition limits grants to service principals"; fi

if grep -q 'PIPELINE_PRINCIPAL_IDS=${PLAN_SP} ${PLATFORM_SP} ${PT_SP} ${STAGING_SP}' "$f"; then
  ok "four pipeline principal IDs are printed"
else bad "four pipeline principal IDs are printed"; fi
if grep -q 'for sp in "$PLAN_SP" "$PLATFORM_SP" "$PT_SP" "$STAGING_SP"; do' "$f"; then
  ok "the Owner cleanup covers tf-staging"
else bad "the Owner cleanup covers tf-staging"; fi
exit $fail
