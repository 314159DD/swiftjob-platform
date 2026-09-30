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
exit $fail
