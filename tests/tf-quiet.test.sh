#!/usr/bin/env bash
# Tests for scripts/tf-quiet.sh. Run: bash tests/tf-quiet.test.sh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
script="$root/scripts/tf-quiet.sh"
export PATH="$root/tests/fake-bin:$PATH"
fail=0
check() { if [[ "$1" == "$2" ]]; then echo "ok   $3"; else echo "FAIL $3 (expected '$2', got '$1')"; fail=1; fi; }

# stdout of terraform never appears
rc=0; out=$(FAKE_TF_EXIT=0 bash "$script" redact plan 2>&1) || rc=$?
check "$rc" 0 "success keeps exit code 0"
check "$(grep -c 'STDOUT-PLAN-TEXT' <<< "$out" || true)" 0 "stdout is discarded"
check "$(grep -c 'Error:' <<< "$out" || true)" 0 "success prints no stderr"

# redact mode prints stderr with identifiers masked
rc=0; out=$(FAKE_TF_EXIT=1 bash "$script" redact plan 2>&1) || rc=$?
check "$rc" 1 "failure keeps exit code 1"
check "$(grep -c 'Error: bad value' <<< "$out" || true)" 1 "redact mode shows the error"
check "$(grep -c '11111111-2222' <<< "$out" || true)" 0 "redact mode masks GUIDs"
check "$(grep -c 'example.com' <<< "$out" || true)" 0 "redact mode masks e-mail"

# suppress mode prints no stderr at all
rc=0; out=$(FAKE_TF_EXIT=1 bash "$script" suppress -chdir=environments/staging plan 2>&1) || rc=$?
check "$rc" 1 "suppress keeps exit code"
check "$(grep -c 'bad value' <<< "$out" || true)" 0 "suppress mode prints no stderr"
check "$(grep -c 'terraform plan failed with exit code 1' <<< "$out" || true)" 1 "suppress mode names subcommand and code"

# allowed exit codes (plan -detailed-exitcode returns 2 for changes)
rc=0; out=$(FAKE_TF_EXIT=2 TF_QUIET_OK_CODES="0 2" bash "$script" suppress plan 2>&1) || rc=$?
check "$rc" 2 "exit code 2 preserved"
check "$out" "" "allowed code prints nothing"

# bad mode
rc=0; bash "$script" loud plan >/dev/null 2>&1 || rc=$?
check "$rc" 64 "unknown mode is a usage error"
exit $fail
