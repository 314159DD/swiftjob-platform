#!/usr/bin/env bash
# Tests for scripts/access-test.sh with stub az and curl. Run: bash tests/access-test.test.sh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
check() { if [[ "$1" == "$2" ]]; then echo "ok   $3"; else echo "FAIL $3 (expected '$2', got '$1')"; fail=1; fi; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"
cat > "$tmp/bin/az" <<'STUB'
#!/usr/bin/env bash
# LEAK=kv|blob|key (that check is allowed) ; NOKV=1 (no vault) ; KVSHOW_FAIL=1 ; CONT=name (container list answer)
case "$*" in
  "keyvault list"*) [[ "${NOKV:-0}" == 1 ]] || printf 'kv-x\r\n' ;;
  "storage account list"*) printf 'sa-x\r\n' ;;
  "storage container-rm list"*) [[ -n "${CONT:-}" ]] && printf '%s\r\n' "$CONT"; exit 0 ;;
  "keyvault show"*) [[ "${KVSHOW_FAIL:-0}" == 1 ]] && { echo "AuthorizationFailed SECRET-DETAIL 935719d3-a4cc-4704-ad6e-b63a410f5043" >&2; exit 1; }; exit 0 ;;
  "keyvault secret list"*) [[ "${LEAK:-}" == kv ]] && exit 0; echo "(Forbidden) ForbiddenByRbac SECRET-DETAIL" >&2; exit 1 ;;
  *"--account-key"*) echo "ProbeKey $*" >> "$ARGLOG"; echo "KeyBasedAuthenticationNotPermitted" >&2; exit 1 ;;
  "storage blob list"*) echo "ProbeBlob $*" >> "$ARGLOG"; [[ "${LEAK:-}" == blob ]] && exit 0; echo "AuthorizationPermissionMismatch" >&2; exit 1 ;;
esac
STUB
cat > "$tmp/bin/curl" <<'STUB'
#!/usr/bin/env bash
# CURL_CODE = status to answer ; CURL_FAIL=1 = network failure
[[ "${CURL_FAIL:-0}" == 1 ]] && exit 6
printf '%s' "${CURL_CODE:-401}"
STUB
chmod +x "$tmp/bin/az" "$tmp/bin/curl"
export PATH="$tmp/bin:$PATH" ARGLOG="$tmp/args"
run() { : > "$ARGLOG"; rc=0; out=$(env "$@" bash "$root/scripts/access-test.sh" rg-x 2>&1) || rc=$?; }
count() { grep -c -- "$1" <<< "$out" || true; }

run CONT=docs
check "$rc" 0 "everything refused passes"; check "$(count '^PASS')" 6 "six checks pass"
check "$(count 'works')" 1 "one control works"; check "$(count '^PASS.* refused')" 5 "five refusals"
check "$(count SECRET-DETAIL)" 0 "raw az text is not printed"
check "$(grep -c -- '-c docs' "$ARGLOG")" 2 "the discovered container is used"
run
check "$rc" 0 "no container: the probe name is used"; check "$(grep -c -- '-c access-probe' "$ARGLOG")" 2 "fallback container"
run LEAK=kv
check "$rc" 1 "an allowed secret list fails"; check "$(count 'FAIL: read secrets without a role was allowed')" 1 "the failure names the check"
run LEAK=blob
check "$rc" 1 "an allowed blob list fails"
run CURL_CODE=200
check "$rc" 1 "anonymous 200 fails"; check "$(count 'FAIL: list secrets anonymously was allowed')" 1 "anonymous vault named"
run CURL_FAIL=1
check "$rc" 1 "a network failure fails closed"
run CURL_CODE=500
check "$rc" 1 "an unexpected status fails"
run KVSHOW_FAIL=1
check "$rc" 1 "a failing control fails"
check "$(count '935719d3')" 0 "the tenant id is redacted"
run NOKV=1
check "$rc" 1 "a missing vault fails"
exit $fail
