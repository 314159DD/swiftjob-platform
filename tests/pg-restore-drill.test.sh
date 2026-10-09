#!/usr/bin/env bash
# Tests for scripts/pg-restore-drill.sh with stub az, psql and curl. Nothing here touches Azure.
# Run: bash tests/pg-restore-drill.test.sh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
check() { if [[ "$1" == "$2" ]]; then echo "ok   $3"; else echo "FAIL $3 (expected '$2', got '$1')"; fail=1; fi; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"
cat > "$tmp/bin/az" <<'STUB'
#!/usr/bin/env bash
# AZ_RESTORE: ok | fail | fail_created (the server exists although restore returned an error)
# AZ_SKU, AZ_LEFTOVER=1 (a drill server is listed), AZ_ADMIN=none, AZ_DELETE_FAIL=1. Calls go to AZ_LOG.
echo "$*" >> "$AZ_LOG"
tmpsrv="$AZ_DIR/created"
secret_err() { echo "ERROR: ($1) /subscriptions/SECRET-SUB/resourceGroups/rg-secret" >&2; }
case "$*" in
  "postgres flexible-server list"*"!contains"*) printf 'psql-swiftjob-staging-src123\r\n' ;;
  "postgres flexible-server list"*"[?contains"*) if [[ "${AZ_LEFTOVER:-0}" == 1 ]]; then echo psql-swiftjob-staging-drill-old; fi; exit 0 ;;
  "postgres flexible-server microsoft-entra-admin list"*)
    if [[ "${AZ_ADMIN:-ok}" == none ]]; then echo None; else printf '11111111-2222-3333-4444-555555555555\tadmin-secret-principal\r\n'; fi ;;
  "postgres flexible-server microsoft-entra-admin create"*) exit 0 ;;
  # Real CLI (2.90): -s/--server-name is the server, -n/--name the rule; there is no --rule-name.
  "postgres flexible-server firewall-rule "*"--rule-name"*) echo "ERROR: unrecognized arguments: --rule-name" >&2; exit 2 ;;
  "postgres flexible-server firewall-rule create"*" -s "*" -n drill-"*) exit 0 ;;
  "postgres flexible-server firewall-rule delete"*" -s "*" -n drill-"*) exit 0 ;;
  "postgres flexible-server firewall-rule "*) echo "ERROR: the following arguments are required: --server-name/-s" >&2; exit 2 ;;
  "postgres flexible-server show"*"-drill-"*)
    if [[ ! -e "$tmpsrv" ]]; then echo "ERROR: (ResourceNotFound) The Resource 'Microsoft.DBforPostgreSQL/flexibleServers/x' was not found." >&2; exit 3; fi
    case "$*" in *"--query state"*) echo Ready ;; *fullyQualifiedDomainName*) echo host-secret.postgres.database.azure.com ;; *) echo name ;; esac ;;
  "postgres flexible-server show"*)
    case "$*" in *sku.name*) echo "${AZ_SKU:-Standard_B1ms}" ;; *fullyQualifiedDomainName*) echo src-secret.postgres.database.azure.com ;; esac ;;
  "postgres flexible-server restore"*)
    case "${AZ_RESTORE:-ok}" in
      ok) touch "$tmpsrv" ;;
      fail) secret_err Conflict; exit 1 ;;
      fail_created) touch "$tmpsrv"; secret_err RequestDisallowedByPolicy; exit 1 ;;
    esac ;;
  "postgres flexible-server delete"*)
    if [[ "${AZ_DELETE_FAIL:-0}" == 1 ]]; then secret_err Forbidden; exit 1; fi
    rm -f "$tmpsrv" ;;
  "account get-access-token"*) echo "TOKEN-SECRET-VALUE" ;;
esac
STUB
cat > "$tmp/bin/psql" <<'STUB'
#!/usr/bin/env bash
# PSQL_MODE: ok | connfail. PSQL_JOBS, PSQL_USERS, PSQL_SCANS, PSQL_MAX: answers. Argv go to PSQL_LOG.
echo "$*" >> "$PSQL_LOG"
[[ -n "${PGPASSWORD:-}" ]] || exit 2
[[ "${PGOPTIONS:-}" == *default_transaction_read_only=on* ]] || { echo "not read-only" >&2; exit 2; }
if [[ "${PSQL_MODE:-ok}" == connfail ]]; then echo "FATAL: password authentication failed host-secret" >&2; exit 2; fi
sql=""; while (( $# )); do if [[ "$1" == -c ]]; then sql=$2; fi; shift; done
case "$sql" in
  *pg_database*) echo appdb ;;
  "select 1") echo 1 ;;
  *"max(version)"*) echo "${PSQL_MAX:-0043_x}" ;;
  *public.jobs*) echo "${PSQL_JOBS:-1500}" ;;
  *public.app_users*) echo "${PSQL_USERS:-12}" ;;
  *public.scan_run*) echo "${PSQL_SCANS:-30}" ;;
  *schema_migrations*) echo 43 ;;
esac
STUB
printf '#!/usr/bin/env bash\necho 203.0.113.77\n' > "$tmp/bin/curl"
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH" AZ_LOG="$tmp/az.log" PSQL_LOG="$tmp/psql.log" AZ_DIR="$tmp"
export DRILL_POLL_S=0 DRILL_RETRY_S=0 DRILL_CONNECT_TRIES=2 DRILL_READY_TIMEOUT_S=5
run() { : > "$AZ_LOG"; : > "$PSQL_LOG"; rm -f "$tmp/created"; rc=0; out=$(env "$@" bash "$root/scripts/pg-restore-drill.sh" ${ARGS:-staging --expected-migration 0043_x} 2>&1) || rc=$?; }
n() { grep -c -- "$1" "$2" || true; }
has() { grep -c -- "$1" <<< "$out" || true; }
leaks() { grep -c -E 'TOKEN-SECRET|SECRET-SUB|rg-secret|host-secret|src-secret|203\.0\.113|admin-secret|11111111-2222|src123' <<< "$out" || true; }
exists() { if [[ -e "$tmp/created" ]]; then echo exists; else echo gone; fi; }

run
check "$rc" 0 "success: exit 0"
check "$(has 'Restore drill PASSED')" 1 "success: reported as passed"
check "$(n 'flexible-server restore .*--source-server psql-swiftjob-staging-src123 --restore-time' "$AZ_LOG")" 1 "success: restores from the source"
check "$(n 'postgres flexible-server delete -g rg-swiftjob-staging -n psql-swiftjob-staging-drill-' "$AZ_LOG")" 1 "success: the temporary server is deleted"
check "$(exists)" gone "success: nothing is left"
check "$(n 'microsoft-entra-admin create .*-s psql-swiftjob-staging-drill-' "$AZ_LOG")" 1 "success: the administrator is added to the temporary server"
check "$(n 'firewall-rule create .*-s psql-swiftjob-staging-drill-' "$AZ_LOG")" 1 "success: the firewall rule goes on the temporary server"
check "$(n 'firewall-rule create .*-s psql-swiftjob-staging-src' "$AZ_LOG")" 0 "success: the source firewall is untouched"
check "$(has 'jobs = 1500')" 1 "success: counts are printed"
check "$(has 'Restore until Ready')" 1 "success: the restore time is printed"
check "$(leaks)" 0 "success: no token, address, host or principal in the output"
check "$(n 'TOKEN-SECRET' "$PSQL_LOG")" 0 "the token is not in psql's arguments"

ARGS="staging --expected-migration 0043_x --minutes-ago 15" run
check "$rc" 0 "minutes-ago is accepted"

run AZ_RESTORE=fail
check "$rc" 1 "restore fails: non-zero"
check "$(n 'flexible-server delete' "$AZ_LOG")" 0 "restore fails before a server exists: nothing to delete"
check "$(has 'No temporary server to delete')" 1 "restore fails: the trap looked first"
check "$(leaks)" 0 "restore fails: az error text is not printed"
check "$(has 'Conflict')" 1 "restore fails: an allowlisted error code is printed"

run AZ_RESTORE=fail_created
check "$rc" 1 "half-made server: non-zero"
check "$(n 'flexible-server delete' "$AZ_LOG")" 1 "half-made server: deleted by the trap"
check "$(exists)" gone "half-made server: gone"

run PSQL_MODE=connfail
check "$rc" 1 "connect fails: non-zero"
check "$(n 'flexible-server delete' "$AZ_LOG")" 1 "connect fails: server deleted"
check "$(leaks)" 0 "connect fails: psql error text is not printed"

run PSQL_JOBS=0
check "$rc" 1 "empty jobs table: non-zero"
check "$(has 'FAIL: jobs')" 1 "empty jobs table: named"
check "$(n 'flexible-server delete' "$AZ_LOG")" 1 "empty jobs table: server deleted"

run PSQL_MAX=0041_old
check "$rc" 1 "migration mismatch: non-zero"
check "$(has 'highest migration is 0041_old, expected 0043_x')" 1 "migration mismatch: named"
check "$(n 'flexible-server delete' "$AZ_LOG")" 1 "migration mismatch: server deleted"

ARGS="staging --expected-migration 0043_x --keep" run
check "$rc" 0 "keep: success"
check "$(n 'flexible-server delete' "$AZ_LOG")" 0 "keep: not deleted"
check "$(exists)" exists "keep: still there"
check "$(has 'NOT deleted')" 1 "keep: says how to delete it"

ARGS="staging --expected-migration 0043_x --keep" run PSQL_MODE=connfail
check "$rc" 1 "keep with a failed sign-in: non-zero"
check "$(n 'flexible-server delete' "$AZ_LOG")" 0 "keep with a failed sign-in: still not deleted"

run AZ_DELETE_FAIL=1
check "$rc" 2 "delete fails: exit 2"
check "$(has 'MAY STILL EXIST')" 1 "delete fails: loud warning"
check "$(leaks)" 0 "delete fails: no az text"

run AZ_SKU=Standard_D4s_v3
check "$rc" 1 "a larger source is refused"
check "$(n 'flexible-server restore' "$AZ_LOG")" 0 "a larger source: nothing restored"
run AZ_SKU=Standard_D4s_v3 DRILL_ALLOW_SKU=1
check "$rc" 0 "a larger source with DRILL_ALLOW_SKU=1 runs"

run AZ_LEFTOVER=1
check "$rc" 1 "a leftover drill server blocks a new one"
check "$(n 'flexible-server restore' "$AZ_LOG")" 0 "leftover: nothing restored"

run AZ_ADMIN=none
check "$rc" 1 "no break-glass administrator: refused before the restore"
check "$(n 'flexible-server restore' "$AZ_LOG")" 0 "no administrator: nothing restored"

ARGS="staging" run
check "$rc" 64 "no expected migration: usage error"
check "$(n 'flexible-server' "$AZ_LOG")" 0 "no expected migration: az not called"
ARGS="staging" run DRILL_COMPARE_SOURCE=1
check "$rc" 0 "expected version read from the source"
check "$(n 'firewall-rule create .*-s psql-swiftjob-staging-src123' "$AZ_LOG")" 1 "compare: a rule is opened on the source"
check "$(n 'firewall-rule delete .*-s psql-swiftjob-staging-src123' "$AZ_LOG")" 1 "compare: and removed again"
ARGS="dev --expected-migration x" run
check "$rc" 64 "unknown environment is refused"
ARGS="prod --expected-migration 0043_x" run
check "$(n 'flexible-server list -g rg-swiftjob-prod' "$AZ_LOG")" 2 "prod uses its own resource group"
ARGS="staging --expected-migration 0043_x --minutes-ago abc" run
check "$rc" 64 "bad minutes-ago is refused"

exit "$fail"
