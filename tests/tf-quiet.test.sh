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
check "$(grep -c 'withheld error summary: types=\[\] codes=\[\] status=\[\]' <<< "$out" || true)" 1 "suppress mode prints an empty summary without matches"

# suppress mode summary: only resource types, Azure error codes and HTTP status, never names or values
azerr='Error: creating Role Assignment (Scope: "/subscriptions/11111111-2222-3333-4444-555555555555/vaults/kv-private-name/secrets/vendor-key"): unexpected status 404 (404 Not Found) with error: ResourceNotFound: StatusCode=404 Code="ResourceNotFound" Message="The resource kv-private-name was not found"
  with module.workload.azurerm_role_assignment.secret_reader["vendor-key|api"],'
rc=0; out=$(FAKE_TF_EXIT=1 FAKE_TF_STDERR="$azerr" bash "$script" suppress -chdir=environments/staging apply tfplan 2>&1) || rc=$?
check "$rc" 1 "summary keeps exit code"
check "$(grep -c 'types=\[azurerm_role_assignment\] codes=\[ResourceNotFound\] status=\[404\]' <<< "$out" || true)" 1 "summary names type, code and status"
check "$(grep -cE 'kv-private-name|vendor-key|secret_reader|11111111|Message' <<< "$out" || true)" 0 "summary leaks no names, keys or ids"

# allowed exit codes (plan -detailed-exitcode returns 2 for changes)
rc=0; out=$(FAKE_TF_EXIT=2 TF_QUIET_OK_CODES="0 2" bash "$script" suppress plan 2>&1) || rc=$?
check "$rc" 2 "exit code 2 preserved"
check "$out" "" "allowed code prints nothing"

# a failing redactor keeps terraform's exit code and leaks no raw stderr
printf '#!/usr/bin/env bash
exit 9
' > "$root/tests/.failing-redact.sh"
rc=0; out=$(FAKE_TF_EXIT=3 TF_QUIET_REDACT="$root/tests/.failing-redact.sh" bash "$script" redact plan 2>&1) || rc=$?
rm -f "$root/tests/.failing-redact.sh"
check "$rc" 3 "failing redactor keeps terraform exit code"
check "$(grep -c 'bad value' <<< "$out" || true)" 0 "failing redactor leaks no raw stderr"
check "$(grep -c 'redaction failed' <<< "$out" || true)" 1 "failing redactor is reported"

# bad mode
rc=0; bash "$script" loud plan >/dev/null 2>&1 || rc=$?
check "$rc" 64 "unknown mode is a usage error"
exit $fail
