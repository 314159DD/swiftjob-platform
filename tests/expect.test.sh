#!/usr/bin/env bash
# Tests for scripts/expect.sh. Run: bash tests/expect.test.sh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "$root/scripts/expect.sh"
fail=0
check() { if [[ "$1" == "$2" ]]; then echo "ok   $3"; else echo "FAIL $3 (expected '$2', got '$1')"; fail=1; fi; }

allowed()  { echo "done"; }
refused()  { echo "ERROR: (AuthorizationFailed) The client '11111111-2222-3333-4444-555555555555' has no access" >&2; return 1; }
other()    { echo "ERROR: connection reset for a.person@example.com" >&2; return 1; }

out=$(expect_refused "refused call" "AuthorizationFailed" refused)
check "$out" "PASS: refused call refused (AuthorizationFailed)" "refusal with the expected code passes"
out=$(expect_refused "allowed call" "AuthorizationFailed" allowed || true)
check "$out" "FAIL: allowed call was allowed" "an allowed call fails the check"
out=$(expect_refused "wrong reason" "AuthorizationFailed" other || true)
check "$(grep -c '^FAIL: wrong reason failed for another reason' <<< "$out")" 1 "refusal for another reason fails"
check "$(grep -c 'example.com' <<< "$out" || true)" 0 "other-reason output is redacted"
out=$(expect_ok "working call" allowed)
check "$out" "PASS: working call works" "expect_ok passes"
out=$(expect_ok "broken call" refused || true)
check "$(grep -c '11111111' <<< "$out" || true)" 0 "expect_ok failure output is redacted"

# An identifier straddling character 300 must be masked whole, not cut into a fragment.
straddle() { printf 'ERROR: %s deadbeef-1234-5678-9abc-def012345678 tail\n' "$(printf 'x%.0s' $(seq 1 285))" >&2; return 1; }
out=$(expect_ok "straddle" straddle || true)
check "$(grep -c 'deadbe' <<< "$out" || true)" 0 "no identifier fragment at the truncation point"

EXPECT_FAILURES=0
expect_refused "a" "AuthorizationFailed" refused > /dev/null
rc=0; expect_summary > /dev/null || rc=$?
check "$rc" 0 "summary passes with no failures"
expect_refused "b" "AuthorizationFailed" allowed > /dev/null || true
rc=0; expect_summary > /dev/null || rc=$?
check "$rc" 1 "summary fails after a failure"
exit $fail
