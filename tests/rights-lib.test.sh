#!/usr/bin/env bash
# Tests for scripts/rights-lib.sh. Run: bash tests/rights-lib.test.sh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "$root/scripts/expect.sh"
# shellcheck source=/dev/null
source "$root/scripts/rights-lib.sh"
fail=0
check() { if [[ "$1" == "$2" ]]; then echo "ok   $3"; else echo "FAIL $3 (expected '$2', got '$1')"; fail=1; fi; }

SELF=00000000-0000-0000-0000-000000000000
CREATED_LOG=$(mktemp)
trap 'rm -f "$CREATED_LOG"' EXIT

PATH="$root/tests/fake-az:$PATH"
out=$(expect_refused "self-grant" "AuthorizationFailed" grant_self "Monitoring Reader" /subscriptions/x)
check "$out" "PASS: self-grant refused (AuthorizationFailed)" "a refused grant is reported as refused"
check "$(wc -c < "$CREATED_LOG" | tr -d ' ')" 0 "a refused grant records nothing"

# An allowed grant: the fake prints an ID and exits 0.
allowed_az() { echo "/subscriptions/x/providers/Microsoft.Authorization/roleAssignments/abc"; }
az() { allowed_az; }
out=$(expect_refused "self-grant" "AuthorizationFailed" grant_self "Monitoring Reader" /subscriptions/x || true)
check "$out" "FAIL: self-grant was allowed" "an allowed grant fails the check"
check "$(wc -l < "$CREATED_LOG" | tr -d " ")" 1 "an allowed grant is recorded even when checked as a refusal"
grant_self "Monitoring Reader" /subscriptions/x
check "$(wc -l < "$CREATED_LOG" | tr -d ' ')" 2 "a direct allowed grant is recorded for cleanup"
grant_to "11111111-1111-1111-1111-111111111111" "Monitoring Metrics Publisher" /subscriptions/x
check "$(wc -l < "$CREATED_LOG" | tr -d " ")" 3 "a grant to another principal is recorded for cleanup"

# The allowed-grant control must fail when the grant is refused (fake az refuses everything).
unset -f az
PIPELINE_PRINCIPAL_IDS="$SELF 22222222-2222-2222-2222-222222222222"
STAGING_RG_ID=/subscriptions/x/resourceGroups/rg
before=$(wc -l < "$CREATED_LOG" | tr -d ' ')
if grant_and_remove_allowed 2> /dev/null; then check pass fail "the control fails when the grant is refused"; else check ok ok "the control fails when the grant is refused"; fi
check "$(wc -l < "$CREATED_LOG" | tr -d ' ')" "$before" "a refused control grant records nothing"
# It also fails when there is no other principal to grant to.
PIPELINE_PRINCIPAL_IDS="$SELF"
if grant_and_remove_allowed 2> /dev/null; then check pass fail "the control fails without another principal"; else check ok ok "the control fails without another principal"; fi
# The user grant fails without RIGHTS_TEST_USER_ID (no skip), and sends the User principal type when it is set.
RIGHTS_TEST_USER_ID=""
if grant_to_user "Monitoring Metrics Publisher" /subscriptions/x 2> /dev/null; then check pass fail "the user grant fails without RIGHTS_TEST_USER_ID"; else check ok ok "the user grant fails without RIGHTS_TEST_USER_ID"; fi
az() { printf '%s ' "$@" > "$CREATED_LOG.args"; echo "/subscriptions/x/providers/Microsoft.Authorization/roleAssignments/user1"; }
RIGHTS_TEST_USER_ID=33333333-3333-3333-3333-333333333333
grant_to_user "Monitoring Metrics Publisher" /subscriptions/x
check "$(grep -c -- '--assignee-principal-type User ' "$CREATED_LOG.args")" 1 "the user grant sends principal type User"
rm -f "$CREATED_LOG.args"
exit $fail
