#!/usr/bin/env bash
# Tests for scripts/smoke-staging.sh with a stub az. Run: bash tests/smoke-staging.test.sh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
check() { if [[ "$1" == "$2" ]]; then echo "ok   $3"; else echo "FAIL $3 (expected '$2', got '$1')"; fail=1; fi; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"
cat > "$tmp/bin/az" <<'STUB'
#!/usr/bin/env bash
# AZ_MODE: ok | notfound | error | empty | none ; AZ_IMAGE ; AZ_EXT_FAIL=1 (extension missing and install fails)
case "$*" in
  "extension show"*) [[ "${AZ_EXT_FAIL:-0}" == 1 ]] && exit 1; exit 0 ;;
  "extension add"*) exit 1 ;;
  "containerapp show"*)
    case "${AZ_MODE:-ok}" in
      ok) printf 'host.example\r\n%s\r\n' "$AZ_IMAGE" ;;
      notfound) echo "(ResourceNotFound) The Resource could not be found" >&2; exit 3 ;;
      error) echo "AuthorizationFailed SECRET-DETAIL" >&2; exit 1 ;;
      empty) exit 0 ;;
      none) printf 'None\nNone\n' ;;
    esac ;;
esac
STUB
chmod +x "$tmp/bin/az"
printf '#!/usr/bin/env bash\necho SMOKE-RAN\n' > "$tmp/smoke.sh"
export PATH="$tmp/bin:$PATH" SMOKE_TEST="$tmp/smoke.sh"
run() { rc=0; out=$(env "$@" bash "$root/scripts/smoke-staging.sh" 2>&1) || rc=$?; }

run AZ_MODE=ok AZ_IMAGE=ghcr.io/o/i:1
check "$rc" 0 "product images run the smoke test"; check "$(grep -c SMOKE-RAN <<< "$out" || true)" 1 "the smoke test ran"
run AZ_MODE=ok AZ_IMAGE=mcr.example/placeholder
check "$rc" 0 "placeholder images skip"; check "$(grep -c 'skipped' <<< "$out" || true)" 1 "the skip is announced"
check "$(grep -c SMOKE-RAN <<< "$out" || true)" 0 "a placeholder does not run the smoke test"
run AZ_MODE=notfound
check "$rc" 0 "a missing app skips"; check "$(grep -c 'No apps deployed' <<< "$out" || true)" 1 "the missing app is announced"
run AZ_MODE=error
check "$rc" 1 "an az error fails the step"; check "$(grep -c SECRET-DETAIL <<< "$out" || true)" 0 "az error text is not printed"
run AZ_MODE=empty
check "$rc" 1 "an empty answer fails the step"
run AZ_MODE=none
check "$rc" 1 "a null image fails the step"
run AZ_MODE=ok AZ_IMAGE=ghcr.io/o/i:1 AZ_EXT_FAIL=1
check "$rc" 1 "a failing extension install fails the step"
exit $fail
