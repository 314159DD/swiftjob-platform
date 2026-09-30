#!/usr/bin/env bash
# Tests for scripts/state-secret-check.sh with a stub terraform. Run: bash tests/state-secret-check.test.sh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
check() { if [[ "$1" == "$2" ]]; then echo "ok   $3"; else echo "FAIL $3 (expected '$2', got '$1')"; fail=1; fi; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat > "$tmp/bin/terraform" <<'STUB'
#!/usr/bin/env bash
[[ "${FAKE_TF_EXIT:-0}" == 0 ]] || exit "$FAKE_TF_EXIT"
cat "$FAKE_STATE"
STUB
chmod +x "$tmp/bin/terraform"
export PATH="$tmp/bin:$PATH"
run() { rc=0; out=$(FAKE_STATE="$1" bash "$root/scripts/state-secret-check.sh" staging 2>&1) || rc=$?; }

echo '{"resources":[{"type":"azurerm_container_app","instances":[{"attributes":{"secret":[{"name":"a","key_vault_secret_id":"x"}]}}]},{"type":"azurerm_container_app_job","instances":[{"attributes":{"secret":[]}}]}]}' > "$tmp/clean.json"
run "$tmp/clean.json"
check "$rc" 0 "references only: passes"
check "$(grep -c "^secret entries with a value: 0$" <<< "$out" || true)" 1 "reports the count"
check "$(grep -c "^container apps and jobs inspected: 2$" <<< "$out" || true)" 1 "reports how many it inspected"

echo '{"resources":[{"type":"azurerm_container_app_job","instances":[{"attributes":{"secret":[{"name":"a","value":"CANARY-VALUE"}]}}]}]}' > "$tmp/dirty.json"
run "$tmp/dirty.json"
check "$rc" 1 "an inline value fails"
check "$(grep -c 'CANARY-VALUE' <<< "$out" || true)" 0 "the value is never printed"

rc=0; out=$(FAKE_TF_EXIT=1 FAKE_STATE="$tmp/clean.json" bash "$root/scripts/state-secret-check.sh" staging 2>&1) || rc=$?
check "$rc" 1 "an unreadable state fails"
echo '{}' > "$tmp/empty.json"
run "$tmp/empty.json"; check "$rc" 1 "an empty state fails"
echo '{"resources":[{"type":"azurerm_resource_group","instances":[{"attributes":{}}]}]}' > "$tmp/other.json"
run "$tmp/other.json"; check "$rc" 0 "a state without container apps or jobs has nothing to check"
check "$(grep -c 'nothing to check' <<< "$out" || true)" 1 "that is announced"
echo '{"resources":[{"type":"azurerm_container_app","instances":[{"attributes":{"name":"x"}}]}]}' > "$tmp/drift.json"
run "$tmp/drift.json"; check "$rc" 1 "a missing secret attribute fails"
check "$(grep -c 'no secret attribute' <<< "$out" || true)" 1 "the drift message is clear"
exit $fail
