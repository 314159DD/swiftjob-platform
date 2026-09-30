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
# LEAK=kv|blob ; KEYS/PUBACC=true|null (account property answers) ; KV_FIREWALL=1 (that check is allowed) ; NOKV=1 (no vault) ; KVSHOW_FAIL=1 ; CONT=name (container list answer)
case "$*" in
  "keyvault list"*) [[ "${NOKV:-0}" == 1 ]] || printf 'kv-x\r\n' ;;
  "storage account list"*) printf 'sa-x\r\n' ;;
  "storage container-rm list"*) [[ -n "${CONT:-}" ]] && printf '%s\r\n' "$CONT"; exit 0 ;;
  "keyvault show"*) [[ "${KVSHOW_FAIL:-0}" == 1 ]] && { echo "AuthorizationFailed SECRET-DETAIL 935719d3-a4cc-4704-ad6e-b63a410f5043" >&2; exit 1; }; exit 0 ;;
  "keyvault secret list"*) [[ "${LEAK:-}" == kv ]] && exit 0
    [[ "${KV_FIREWALL:-0}" == 1 ]] && { echo "(Forbidden) Client address is not authorized and caller is not a trusted service SECRET-DETAIL" >&2; exit 1; }
    echo "(Forbidden) Caller is not authorized to perform action on resource. SECRET-DETAIL" >&2; exit 1 ;;
  "storage account show"*) v=${KEYS:-false}; [[ "$*" == *allowBlobPublicAccess* ]] && v=${PUBACC:-false}
    [[ "$v" == null ]] && exit 0; echo "$v" ;;
  "storage blob list"*) echo "ProbeBlob $*" >> "$ARGLOG"; [[ "${LEAK:-}" == blob ]] && exit 0
    echo "You do not have the required permissions needed to perform this operation. Depending on your operation, you may need to be assigned one of the following roles: Storage Blob Data Reader SECRET-DETAIL" >&2; exit 1 ;;
  "postgres flexible-server list"*)
    [[ "${PG_LIST_FAIL:-0}" == 1 ]] && { echo "AuthorizationFailed SECRET-DETAIL 935719d3-a4cc-4704-ad6e-b63a410f5043" >&2; exit 1; }
    [[ "${PG:-0}" == 1 ]] && printf 'psql-x\r\n'; exit 0 ;;
  "postgres flexible-server show"*)
    [[ "${PG_SHOW_FAIL:-0}" == 1 ]] && { echo "AuthorizationFailed SECRET-DETAIL" >&2; exit 1; }
    case "$*" in
      *fullyQualifiedDomainName*) printf 'psql-x.postgres.database.azure.com\r\n' ;;
      *state*) printf '%s\r\n' "${PG_STATE:-Ready}" ;;
      *passwordAuth*) printf '%s\r\n' "${PG_PW:-Disabled}" ;;
      *activeDirectoryAuth*) printf '%s\r\n' "${PG_AAD:-Enabled}" ;;
    esac ;;
  "postgres flexible-server parameter show"*) [[ "$*" == *require_secure_transport* ]] && printf '%s\r\n' "${PG_TLS:-on}" ;;
  "postgres flexible-server firewall-rule create"*) echo "FwCreate $*" >> "$ARGLOG"; [[ "${FW_FAIL:-0}" == 1 ]] && exit 1; exit 0 ;;
  "postgres flexible-server firewall-rule delete"*) echo "FwDelete $*" >> "$ARGLOG" ;;
  "account get-access-token"*) printf 'eyJ-probe-token\r\n' ;;
  "account show"*) printf 'runner-principal\r\n' ;;
esac
STUB
cat > "$tmp/bin/psql" <<'STUB'
#!/usr/bin/env bash
# PG_LEAK=password|token|plain (that sign-in succeeds) ; PG_NET=1 (network failure)
[[ "${PG_NET:-0}" == 1 ]] && { echo 'psql: error: connection to server at "psql-x" failed: timeout expired' >&2; exit 2; }
kind=token; [[ "${PGPASSWORD:-}" == wrong-password-probe ]] && kind=password; [[ "$*" == *sslmode=disable* ]] && kind=plain
[[ "${PG_LEAK:-}" == "$kind" ]] && { echo 1; exit 0; }
case "$kind" in
  plain) echo 'psql: error: connection to server failed: FATAL:  no pg_hba.conf entry for host "1.2.3.4", user "access-probe", database "postgres", no encryption SECRET-DETAIL' >&2 ;;
  token) echo 'psql: error: connection to server failed: FATAL:  password authentication failed for user "runner-principal" SECRET-DETAIL' >&2 ;;
  *) echo 'psql: error: connection to server failed: FATAL:  password authentication failed for user "access-probe" SECRET-DETAIL' >&2 ;;
esac
exit 2
STUB
cat > "$tmp/bin/curl" <<'STUB'
#!/usr/bin/env bash
# CURL_CODE = status to answer ; CURL_FAIL=1 = network failure
[[ "$*" == *api.ipify.org* ]] && { printf '%s' "${RUNNER_IP:-1.2.3.4}"; exit 0; }
[[ "${CURL_FAIL:-0}" == 1 ]] && exit 6
[[ "$*" == *blob.core* && -n "${CURL_BLOB:-}" ]] && { printf "%s" "$CURL_BLOB"; exit 0; }
printf '%s' "${CURL_CODE:-401}"
STUB
chmod +x "$tmp/bin/az" "$tmp/bin/curl" "$tmp/bin/psql"
export PATH="$tmp/bin:$PATH" ARGLOG="$tmp/args"
run() { : > "$ARGLOG"; rc=0; out=$(env "$@" bash "$root/scripts/access-test.sh" rg-x 2>&1) || rc=$?; }
count() { grep -c -- "$1" <<< "$out" || true; }

run CONT=docs
check "$rc" 0 "everything refused passes"; check "$(count '^PASS')" 7 "seven checks pass"
check "$(count '^PASS.* works')" 3 "three checks work"; check "$(count '^PASS.* refused')" 4 "four refusals"
check "$(count SECRET-DETAIL)" 0 "raw az text is not printed"
check "$(grep -c -- '-c docs' "$ARGLOG")" 1 "the discovered container is used"
run
check "$rc" 0 "no container: the probe name is used"; check "$(grep -c -- '-c access-probe' "$ARGLOG")" 1 "fallback container"
run LEAK=kv
check "$rc" 1 "an allowed secret list fails"; check "$(count 'FAIL: read secrets without a role was allowed')" 1 "the failure names the check"
run LEAK=blob
check "$rc" 1 "an allowed blob list fails"
run KEYS=true
check "$rc" 1 "shared key enabled fails"; check "$(count 'FAIL: account keys are switched off')" 1 "shared key named"
run KEYS=null
check "$rc" 1 "a missing property fails"
run PUBACC=true
check "$rc" 1 "public blob access enabled fails"
run KV_FIREWALL=1
check "$rc" 1 "a firewall Forbidden is not an RBAC refusal"
run CURL_CODE=404
check "$rc" 1 "anonymous 404 fails"
run CURL_BLOB=409
check "$rc" 0 "anonymous 409 is refused"
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

# PostgreSQL checks
run
check "$rc" 0 "no server: the run passes"; check "$(count 'INFO: no PostgreSQL server')" 1 "and says it skipped the database checks"
check "$(count 'sign-in with a')" 0 "no sign-in check runs without a server"
run PG_LIST_FAIL=1
check "$rc" 1 "a discovery error fails closed"; check "$(count 'FAIL: PostgreSQL server discovery failed')" 1 "and says so"
check "$(count SECRET-DETAIL)" 0 "the discovery error text is not printed"; check "$(count '935719d3')" 0 "no tenant id either"
run PG=1
check "$rc" 0 "database refusals pass"; check "$(count '^PASS')" 13 "thirteen checks pass"
check "$(count SECRET-DETAIL)" 0 "raw psql text is not printed"; check "$(count eyJ-probe)" 0 "the token is not printed"
check "$(grep -c FwCreate "$ARGLOG")" 1 "a probe rule is opened"; check "$(grep -c FwDelete "$ARGLOG")" 1 "and removed again"
run PG=1 PG_LEAK=password
check "$rc" 1 "a password sign-in that works fails"; check "$(count 'FAIL: sign-in with a password was allowed')" 1 "named"
check "$(grep -c FwDelete "$ARGLOG")" 1 "the rule is removed on failure too"
run PG=1 PG_LEAK=token
check "$rc" 1 "a foreign identity that gets in fails"; check "$(count 'FAIL: sign-in with a foreign Entra identity was allowed')" 1 "named"
run PG=1 PG_LEAK=plain
check "$rc" 1 "a sign-in without TLS that works fails"; check "$(count 'FAIL: sign-in without TLS was allowed')" 1 "named"
run PG=1 PG_NET=1
check "$rc" 1 "a network failure is not a refusal"; check "$(count '^PASS: sign-in')" 0 "no sign-in counts as refused"
run PG=1 PG_PW=Enabled
check "$rc" 1 "password auth enabled fails"
run PG=1 PG_AAD=Disabled
check "$rc" 1 "Entra sign-in switched off fails"
run PG=1 PG_TLS=off
check "$rc" 1 "TLS not required fails"
run PG=1 PG_SHOW_FAIL=1
check "$rc" 1 "a failing server read fails closed"; check "$(count SECRET-DETAIL)" 0 "and prints no raw text"
check "$(grep -c FwCreate "$ARGLOG")" 0 "no rule when the state is unknown"
run PG=1 PG_STATE=Stopped
check "$rc" 0 "a stopped server skips the sign-in checks"; check "$(count 'INFO: database stopped')" 1 "and says so"
check "$(grep -c FwCreate "$ARGLOG")" 0 "no rule for a stopped server"
run REQUIRE_POSTGRES=1
check "$rc" 1 "a missing server fails when one is required"
run PG=1 RUNNER_IP=not-an-ip
check "$rc" 1 "an unusable runner address fails closed"; check "$(grep -c FwCreate "$ARGLOG")" 0 "and opens no rule"
run PG=1 FW_FAIL=1
check "$rc" 1 "a probe rule that cannot be created fails"; check "$(count 'FAIL: probe firewall rule not created')" 1 "and says so"
check "$(count 'sign-in with a')" 0 "no sign-in check runs without the rule"
exit $fail
