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
  "keyvault show"*) [[ "${KVSHOW_FAIL:-0}" == 1 ]] && { echo "AuthorizationFailed SECRET-DETAIL 00000000-1111-2222-3333-444444444444" >&2; exit 1; }; exit 0 ;;
  "keyvault secret list"*) [[ "${LEAK:-}" == kv ]] && exit 0
    [[ "${KV_FIREWALL:-0}" == 1 ]] && { echo "(Forbidden) Client address is not authorized and caller is not a trusted service SECRET-DETAIL" >&2; exit 1; }
    echo "(Forbidden) Caller is not authorized to perform action on resource. SECRET-DETAIL" >&2; exit 1 ;;
  "storage account show"*) v=${KEYS:-false}; [[ "$*" == *allowBlobPublicAccess* ]] && v=${PUBACC:-false}
    [[ "$v" == null ]] && exit 0; echo "$v" ;;
  "storage blob list"*) echo "ProbeBlob $*" >> "$ARGLOG"; [[ "${LEAK:-}" == blob ]] && exit 0
    echo "You do not have the required permissions needed to perform this operation. Depending on your operation, you may need to be assigned one of the following roles: Storage Blob Data Reader SECRET-DETAIL" >&2; exit 1 ;;
  "postgres flexible-server list"*)
    [[ "${PG_LIST_FAIL:-0}" == 1 ]] && { echo "AuthorizationFailed SECRET-DETAIL 00000000-1111-2222-3333-444444444444" >&2; exit 1; }
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
  "postgres flexible-server firewall-rule delete"*) echo "FwDelete $*" >> "$ARGLOG"; [[ "${FW_DELETE_FAIL:-0}" == 1 ]] && { echo "Throttled SECRET-DETAIL" >&2; exit 1; }; exit 0 ;;
  "postgres flexible-server firewall-rule list"*)
    [[ "${FW_LIST_FAIL:-0}" == 1 ]] && { echo "AuthorizationFailed SECRET-DETAIL" >&2; exit 1; }
    if [[ "$*" == *starts_with* ]]; then printf '%s\r\n' ${FW_LEFT:-}   # the cleanup script's query
    elif [[ "$*" == *"name=="* ]]; then [[ "${FW_STUCK:-0}" == 1 ]] && printf 'probe\r\n'   # the test's own rule after its delete
    else printf '%s\r\n' ${FW_EXTRA:-}; fi   # every rule but the Azure-services one
    exit 0 ;;
  "account get-access-token"*) [[ "${TOKEN_FAIL:-0}" == 1 ]] && exit 1
    # A JWT-shaped token: TOKEN_AUD and TOKEN_EXP shape the claims the control reads.
    printf 'eyJ-probe.%s.sig\r\n' "$(printf '{"aud":"%s","exp":%s}' "${TOKEN_AUD:-https://ossrdbms-aad.database.windows.net}" "${TOKEN_EXP:-4102444800}" | base64 | tr -d '\n=' | tr '+/' '-_')" ;;
  "account show"*) printf '0d0d0d0d-1111-2222-3333-444444444444\r\n' ;;
esac
STUB
cat > "$tmp/bin/psql" <<'STUB'
#!/usr/bin/env bash
# PG_LEAK=password|token|plain (that sign-in succeeds) ; PG_NET=1 (network failure) ; PG_ROLE=1 (the token refusal names a missing role) ; PG_OTHER=1 (the token refusal is an unrelated error)
echo "PsqlCall $*" >> "$ARGLOG"
[[ "${PG_NET:-0}" == 1 ]] && { echo 'psql: error: connection to server at "psql-x" failed: timeout expired' >&2; exit 2; }
kind=token; [[ "${PGPASSWORD:-}" == wrong-password-probe ]] && kind=password; [[ "$*" == *sslmode=disable* ]] && kind=plain
[[ "${PG_LEAK:-}" == "$kind" ]] && { echo 1; exit 0; }
case "$kind" in
  plain) echo 'psql: error: connection to server failed: FATAL:  no pg_hba.conf entry for host "1.2.3.4", user "access-probe", database "postgres", no encryption SECRET-DETAIL' >&2 ;;
  token) if [[ "${PG_OTHER:-0}" == 1 ]]; then echo 'psql: error: connection to server failed: FATAL:  too many connections for role "swiftjob test" SECRET-DETAIL' >&2
         elif [[ "${PG_ROLE:-0}" == 1 ]]; then echo 'psql: error: connection to server at "psql-x" (1.2.3.4), port 5432 failed: FATAL:  role "swiftjob test" does not exist SECRET-DETAIL' >&2
         else echo 'psql: error: connection to server at "psql-x" (1.2.3.4), port 5432 failed: FATAL:  password authentication failed for user "swiftjob test" SECRET-DETAIL' >&2; fi ;;
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
run() { : > "$ARGLOG"; rc=0; out=$(env ALLOW_PROBE_RULE=1 PG_PROBE_USER="swiftjob test" "$@" bash "$root/scripts/access-test.sh" rg-x 2>&1) || rc=$?; }
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
check "$(count '00000000-1111')" 0 "the tenant id is redacted"
run NOKV=1
check "$rc" 1 "a missing vault fails"

# PostgreSQL checks
run
check "$rc" 0 "no server: the run passes"; check "$(count 'INFO: no PostgreSQL server')" 1 "and says it skipped the database checks"
check "$(count 'sign-in with a')" 0 "no sign-in check runs without a server"
run PG_LIST_FAIL=1
check "$rc" 1 "a discovery error fails closed"; check "$(count 'FAIL: PostgreSQL server discovery failed')" 1 "and says so"
check "$(count SECRET-DETAIL)" 0 "the discovery error text is not printed"; check "$(count '00000000-1111')" 0 "no tenant id either"
run PG=1
check "$rc" 0 "database refusals pass"; check "$(count '^PASS')" 14 "fourteen checks pass (the token control included)"
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

# Review round 1
run PG=1
check "$(grep -c "PsqlCall.*user='swiftjob test' " "$ARGLOG")" 1 "C1: the foreign identity signs in under the display name, not the account id"
check "$(grep -c "PsqlCall.*0d0d0d0d" "$ARGLOG")" 0 "C1: the client id from account show is never the user"
check "$(grep -c -- "--name access-test-[A-Za-z0-9]*-[0-9]" "$ARGLOG")" 2 "M1: the rule name carries the run id prefix (create and delete)"
run PG=1 PG_PROBE_USER=
check "$rc" 1 "C1: no display name fails closed"; check "$(count 'FAIL: PG_PROBE_USER')" 1 "and says so"
check "$(grep -c FwCreate "$ARGLOG")" 0 "no rule is opened without it"
run PG=1 PG_OTHER=1
check "$rc" 1 "C1: an unrelated error is not a refusal of the foreign identity"
check "$(count 'FAIL: sign-in with a foreign Entra identity failed for another reason')" 1 "named"
run PG=1 PG_ROLE=1
check "$rc" 0 "a missing-role refusal still passes with the control"
check "$(count 'PASS: sign-in with a foreign Entra identity refused')" 1 "named"

# Token control for the foreign-identity refusal
run PG=1
check "$(count 'PASS: control: the Entra token for the PostgreSQL scope is valid works')" 1 "control ok and foreign refused: both pass"
check "$(count 'PASS: sign-in with a foreign Entra identity refused (identity not mapped to a role, token control passed)')" 1 "and the label says the control passed"
run PG=1 TOKEN_FAIL=1
check "$rc" 1 "no token: the run fails"; check "$(count 'FAIL: sign-in with a foreign Entra identity could not run, token control failed')" 1 "the foreign check reports could not run"
check "$(count '^PASS: sign-in with a foreign')" 0 "and is not a PASS"; check "$(grep -c "PsqlCall.*user='swiftjob test' " "$ARGLOG")" 0 "the foreign sign-in is not attempted"
run PG=1 TOKEN_EXP=1000
check "$rc" 1 "an expired token fails the control"; check "$(count '^PASS: sign-in with a foreign')" 0 "and the refusal is not counted"
run PG=1 TOKEN_AUD=https://management.azure.com
check "$rc" 1 "a token for another service fails the control"; check "$(count 'could not run, token control failed')" 1 "named"
run PG=1 TOKEN_FAIL=1 PG_LEAK=token
check "$rc" 1 "a failing control and a foreign sign-in that would work still fails"
run PG=1 FW_EXTRA=access-test-99-1
check "$rc" 1 "I1: a leftover probe rule fails"; check "$(count 'FAIL: leftover firewall rule found')" 1 "named"
check "$(grep -c -- "FwDelete.*--name access-test-99-1" "$ARGLOG")" 1 "and is deleted"
check "$(grep -c FwCreate "$ARGLOG")" 0 "and no new rule is opened"
run PG=1 FW_EXTRA=break-glass
check "$rc" 1 "I1: any other extra rule fails"; check "$(grep -c FwDelete "$ARGLOG")" 0 "and is left alone"
run PG=1 FW_LIST_FAIL=1
check "$rc" 1 "I1: an unreadable rule list fails closed"; check "$(count SECRET-DETAIL)" 0 "without raw text"
check "$(grep -c FwCreate "$ARGLOG")" 0 "and opens no rule"
run PG=1 FW_DELETE_FAIL=1
check "$rc" 1 "I2: a failed delete fails the run"; check "$(count 'FAIL: probe firewall rule not removed')" 1 "named"
check "$(count 'all checks passed')" 0 "and never prints the success line"; check "$(count SECRET-DETAIL)" 0 "without raw text"
run PG=1 FW_STUCK=1
check "$rc" 1 "I2: a rule still listed after the delete fails"; check "$(count 'FAIL: probe firewall rule not removed')" 1 "named"
run PG=1
check "$(count '1\.2\.3\.4')" 0 "I3: no address in the output"; check "$(count 'swiftjob test')" 0 "I3: no principal name in the output"
check "$(count 'PASS: sign-in with a foreign Entra identity refused (identity not mapped to a role, token control passed)')" 1 "I3: a fixed label instead of the psql text"
run PG=1 PG_LEAK=plain
check "$(count '1\.2\.3\.4')" 0 "I3: no address in a failure line either"
run PG=1 ALLOW_PROBE_RULE=0
check "$rc" 0 "I5: without the flag the run skips the sign-in checks"; check "$(count 'INFO: sign-in checks need a probe firewall rule')" 1 "and says so"
check "$(grep -c FwCreate "$ARGLOG")" 0 "I5: no rule is opened"
run PG=1 ALLOW_PROBE_RULE=0 REQUIRE_POSTGRES=1
check "$rc" 1 "I5: with REQUIRE_POSTGRES the missing flag fails"
run PG=1 PG_STATE=Stopped REQUIRE_POSTGRES=1
check "$rc" 1 "M4: a stopped server fails when the database is required"

# scripts/access-test-cleanup.sh
cleanup() { : > "$ARGLOG"; rc=0; out=$(env "$@" bash "$root/scripts/access-test-cleanup.sh" rg-x 2>&1) || rc=$?; }
cleanup PG=1
check "$rc" 0 "cleanup: nothing to remove passes"; check "$(grep -c FwDelete "$ARGLOG")" 0 "and deletes nothing"
cleanup PG=1 FW_LEFT="access-test-1-2 access-test-3-4"
check "$rc" 0 "cleanup: leftovers are removed"; check "$(grep -c FwDelete "$ARGLOG")" 2 "both of them"
cleanup PG=1 FW_LEFT=access-test-1-2 FW_DELETE_FAIL=1
check "$rc" 1 "cleanup: a failed delete fails the step"; check "$(count SECRET-DETAIL)" 0 "without raw text"
cleanup PG=1 FW_LIST_FAIL=1
check "$rc" 1 "cleanup: an unreadable list fails the step"
cleanup
check "$rc" 0 "cleanup: no server passes"
cleanup PG_LIST_FAIL=1
check "$rc" 1 "cleanup: a failed server lookup fails the step"
exit $fail
