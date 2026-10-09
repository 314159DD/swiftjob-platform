#!/usr/bin/env bash
# Tests for scripts/prod-guard.py on crafted plan JSON. Run: bash tests/prod-guard.test.sh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
guard="$root/scripts/prod-guard.py"
fail=0
check() { if [[ "$1" == "$2" ]]; then echo "ok   $3"; else echo "FAIL $3 (expected '$2', got '$1')"; fail=1; fi; }
plan() { # type actions-json
  printf '{"format_version":"1.2","resource_changes":[{"address":"module.workload.%s.this[0]","type":"%s","change":{"actions":%s}},{"address":"x.y","type":"azurerm_container_app","change":{"actions":["delete","create"]}}]}' "$1" "$1" "$2"
}
run() { rc=0; out=$(python3 "$guard" 2>&1) || rc=$?; }

for t in azurerm_postgresql_flexible_server azurerm_storage_account azurerm_key_vault; do
  plan "$t" '["delete"]' | { run; check "$rc" 1 "$t delete fails"; }
  rc=0; out=$(plan "$t" '["delete","create"]' | python3 "$guard" 2>&1) || rc=$?
  check "$rc" 1 "$t replace fails"
  check "$(grep -c 'would replace' <<< "$out" || true)" 1 "$t replace is named as replace"
  check "$(grep -c 'module.workload' <<< "$out" || true)" 0 "$t: no address is printed"
  rc=0; out=$(plan "$t" '["update"]' | python3 "$guard" 2>&1) || rc=$?
  check "$rc" 0 "$t update passes"
  rc=0; out=$(plan "$t" '["create"]' | python3 "$guard" 2>&1) || rc=$?
  check "$rc" 0 "$t create passes"
done

# a replaced container app (not guarded) passes: only the three data resources are protected
rc=0; out=$(echo '{"format_version":"1.2","resource_changes":[{"type":"azurerm_container_app","change":{"actions":["delete","create"]}}]}' | python3 "$guard" 2>&1) || rc=$?
check "$rc" 0 "an app replacement passes"
rc=0; out=$(echo '{"format_version":"1.2"}' | python3 "$guard" 2>&1) || rc=$?
check "$rc" 0 "a plan without changes passes"
# fail closed on anything that is not a plan
rc=0; out=$(echo 'not json' | python3 "$guard" 2>&1) || rc=$?
check "$rc" 2 "garbage input fails closed"
rc=0; out=$(echo '[]' | python3 "$guard" 2>&1) || rc=$?
check "$rc" 2 "a JSON list fails closed"
rc=0; out=$(printf '' | python3 "$guard" 2>&1) || rc=$?
check "$rc" 2 "empty input fails closed"
exit $fail
