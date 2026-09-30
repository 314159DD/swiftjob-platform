#!/usr/bin/env bash
# Tests for scripts/state-check.sh with an az shim. Run: bash tests/state-check.test.sh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
script="$root/scripts/state-check.sh"
shim="$(mktemp -d)"; trap 'rm -rf "$shim"' EXIT
cat > "$shim/az" <<'SH'
#!/usr/bin/env bash
# Behaviour is set by FAKE_EXISTS (true|false|fail|maybe), FAKE_COUNT (number|fail) and FAKE_RG_EXISTS (true|false).
case "$1 $2" in
  "storage blob") [[ "$FAKE_EXISTS" == fail ]] && { echo "AuthorizationFailed" >&2; exit 1; }; echo "$FAKE_EXISTS" ;;
  "resource list") [[ "$FAKE_COUNT" == fail ]] && { echo "ResourceGroupNotFound" >&2; exit 1; }; echo "$FAKE_COUNT" ;;
  "group exists") echo "${FAKE_RG_EXISTS:-true}" ;;
  *) echo "unexpected az call: $*" >&2; exit 9 ;;
esac
SH
chmod +x "$shim/az"
export PATH="$shim:$PATH" TF_STATE_SA=sa
fail=0
run() { # name expected-exit expected-text [layer]
  local out rc=0
  out=$(bash "$script" "${4:-staging}" 2>&1) || rc=$?
  if [[ "$rc" == "$2" && "$out" == *"$3"* ]]; then echo "ok   $1"; else echo "FAIL $1 -> $rc '$out'"; fail=1; fi
}
FAKE_EXISTS=true FAKE_COUNT=5 run "state exists" 0 ""
FAKE_EXISTS=false FAKE_COUNT=0 run "no state, empty group skips" 3 "first apply pending"
FAKE_EXISTS=false FAKE_COUNT=4 run "no state, resources present fails" 1 "state for staging is missing but its resource group has resources"
FAKE_EXISTS=false FAKE_COUNT=fail FAKE_RG_EXISTS=false run "no state, group absent skips" 3 "first apply pending"
FAKE_EXISTS=false FAKE_COUNT=fail FAKE_RG_EXISTS=true run "no state, list fails" 1 "could not list"
FAKE_EXISTS=fail FAKE_COUNT=0 run "blob check fails" 1 "state check for staging failed"
FAKE_EXISTS=maybe FAKE_COUNT=0 run "unexpected blob answer" 1 "unexpected answer"
FAKE_EXISTS=true FAKE_COUNT=0 run "unknown layer" 1 "no resource group known" other
exit $fail
