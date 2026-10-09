#!/usr/bin/env bash
# Point-in-time-restore drill for the PostgreSQL flexible server of one environment (runbook: docs/runbooks/restore.md).
# It restores the server to a NEW temporary server, signs in as the break-glass Entra administrator, runs read-only
# checks, prints the timings (the restore time is the RTO measurement) and deletes the temporary server again.
# Usage: bash scripts/pg-restore-drill.sh <staging|prod> [--keep] [--minutes-ago N] [--expected-migration VERSION]
#
#   --keep               do not delete the temporary server (it bills until you delete it; the script says how)
#   --minutes-ago N      restore point, N minutes before now (default 60)
#   --expected-migration the highest migrations.schema_migrations.version the restore must contain, for example
#                        0043_name. Without it (and without DRILL_COMPARE_SOURCE=1) the script refuses to start,
#                        before it creates anything.
#
# Run by the owner, signed in with az as the Entra administrator of the server (ADR 9), with psql installed.
# It creates a billable resource (a second Burstable B1ms server for the duration of the drill, about an hour at
# most), so it never runs in CI; the tests use stubs.
#
# What it does, in order:
#   1. resolves the source server in rg-swiftjob-<env> (the only server that is not a drill server) and refuses
#      to start when a drill server is left over or the source is not Standard_B1ms (cost guard; the restore keeps
#      the source's compute tier and size)
#   2. `az postgres flexible-server restore` to a new server named psql-swiftjob-<env>-drill-<UTC timestamp>
#   3. waits for state Ready (restore start to Ready is printed)
#   4. a restore copies neither firewall rules nor Entra administrators (Microsoft Learn, "Post-restore tasks"), so it
#      adds the break-glass administrator (taken from the source server's Entra administrators, type User) and a
#      firewall rule for this machine's address, both on the TEMPORARY server only
#   5. signs in with an Entra token (az account get-access-token --resource-type oss-rdbms), in a read-only session
#      (default_transaction_read_only=on), and checks: row counts of jobs, app_users and scan_run, and the highest
#      migration version against the expected one
#   6. the EXIT trap deletes the temporary server (unless --keep), also after a failed or interrupted restore: it looks
#      the server up first and deletes whatever exists. Exit codes: 0 all checks passed, 1 a check or a step failed,
#      2 the temporary server could not be deleted (delete it by hand), 64 usage.
#
# Output: fixed messages, counts and timings only. The token is passed to psql in PGPASSWORD (never in argv), az and
# psql error text is never printed, and neither are connection strings, host names, addresses or principal names.
#
# Env (all optional):
#   DRILL_RG                    resource group (default rg-swiftjob-<env>)
#   DRILL_SOURCE_SERVER         source server name, instead of discovery
#   DRILL_PG_USER               sign-in name of the administrator (default: principal name from the source's admin list)
#   DRILL_ADMIN_OBJECT_ID       its object id (default: from the source's admin list)
#   DRILL_MY_IP                 this machine's public IPv4 address (default: asked from api.ipify.org)
#   DRILL_DATABASE              application database (default: the only non-system database)
#   DRILL_SET_ROLE              role to SET ROLE to before the counts, when row level security hides rows from the admin
#   DRILL_MIN_JOBS (1), DRILL_MIN_USERS (0), DRILL_MIN_SCAN_RUNS (0)   minimum row counts that count as a pass
#   DRILL_COMPARE_SOURCE=1      read the expected migration version from the source (opens a temporary firewall rule
#                               for this machine on the SOURCE server, removed again by the trap)
#   DRILL_ALLOW_SKU=1           allow a source that is not Standard_B1ms (the drill then costs more)
#   DRILL_SSLMODE (require), DRILL_READY_TIMEOUT_S (1800), DRILL_POLL_S (15), DRILL_CONNECT_TRIES (12), DRILL_RETRY_S (15)
set -euo pipefail
export MSYS_NO_PATHCONV=1

env_name=${1:-}; shift || true
keep=0; minutes=60; expected=${DRILL_EXPECTED_MIGRATION:-}
case "$env_name" in staging|prod) ;; *) echo "usage: pg-restore-drill.sh <staging|prod> [--keep] [--minutes-ago N] [--expected-migration VERSION]" >&2; exit 64 ;; esac
while (( $# > 0 )); do
  case "$1" in
    --keep) keep=1 ;;
    --minutes-ago) shift; minutes=${1:-}; [[ "$minutes" =~ ^[1-9][0-9]{0,5}$ ]] || { echo "::error::--minutes-ago needs a positive number" >&2; exit 64; } ;;
    --expected-migration) shift; expected=${1:-} ;;
    *) echo "::error::unknown argument" >&2; exit 64 ;;
  esac
  shift || true
done
[[ -z "$expected" || "$expected" =~ ^[0-9A-Za-z_]{1,120}$ ]] || { echo "::error::--expected-migration is not a migration version" >&2; exit 64; }
if [[ -z "$expected" && "${DRILL_COMPARE_SOURCE:-0}" != 1 ]]; then
  echo "::error::pass --expected-migration <version> (the highest migration of the database) or set DRILL_COMPARE_SOURCE=1" >&2; exit 64
fi

rg=${DRILL_RG:-rg-swiftjob-${env_name}}
ready_timeout=${DRILL_READY_TIMEOUT_S:-1800}; poll_s=${DRILL_POLL_S:-15}
tries=${DRILL_CONNECT_TRIES:-12}; retry_s=${DRILL_RETRY_S:-15}
sslmode=${DRILL_SSLMODE:-require}
min_jobs=${DRILL_MIN_JOBS:-1}; min_users=${DRILL_MIN_USERS:-0}; min_scans=${DRILL_MIN_SCAN_RUNS:-0}
tmp_name="psql-swiftjob-${env_name}-drill-$(date -u +%Y%m%d%H%M%S)"
rule="drill-$$"
err=$(mktemp)
src=""; src_rule_open=0; created=0
fail=0

say() { echo "$*"; }
bad() { echo "FAIL: $*"; fail=1; }
# At most one allowlisted Azure error code from the last failed az call.
code() { { grep -oE '\((AuthorizationFailed|ResourceNotFound|ResourceGroupNotFound|Forbidden|Conflict|RequestDisallowedByPolicy|InvalidAuthenticationToken|ExpiredAuthenticationToken|ServerNotReady|InvalidParameterValue|RestorePointNotAvailable|SkuNotAvailable|QuotaExceeded)\)' "$err" || true; } | head -1 | tr -d '()'; }
now() { date +%s; }

cleanup() {
  local rc=$? gone=0
  trap - EXIT INT TERM
  set +e
  if (( src_rule_open == 1 )); then
    az postgres flexible-server firewall-rule delete -g "$rg" -s "$src" -n "$rule" --yes -o none > /dev/null 2> "$err" \
      || echo "::warning::could not remove the temporary firewall rule from the source server; remove it by hand ($(code))"
  fi
  if (( keep == 1 )); then
    if (( created == 1 )); then
      echo "--keep: the temporary server was NOT deleted. It bills until you delete it:"
      echo "  az postgres flexible-server delete -g ${rg} -n ${tmp_name} --yes"
    fi
    rm -f "$err"; exit "$rc"
  fi
  if (( created == 0 )); then rm -f "$err"; exit "$rc"; fi
  # Look first, so a half-finished restore is deleted too and a server that never came to exist is not an error.
  az postgres flexible-server show -g "$rg" -n "$tmp_name" --query name -o tsv > /dev/null 2> "$err"
  local show_rc=$?
  if (( show_rc != 0 )) && grep -q 'ResourceNotFound' "$err"; then
    gone=1
  else
    echo "Deleting the temporary server"
    if az postgres flexible-server delete -g "$rg" -n "$tmp_name" --yes -o none > /dev/null 2> "$err"; then
      echo "Temporary server deleted"
    else
      echo "::error::THE TEMPORARY SERVER MAY STILL EXIST AND BILLS. Delete it: az postgres flexible-server delete -g ${rg} -n ${tmp_name} --yes ($(code))"
      (( rc == 0 )) && rc=2
    fi
  fi
  (( gone == 1 )) && echo "No temporary server to delete"
  rm -f "$err"
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

command -v psql > /dev/null || { echo "::error::psql is not installed"; exit 1; }

# ---- 1. source server and guards -------------------------------------------------------------------------------
if [[ -n "${DRILL_SOURCE_SERVER:-}" ]]; then
  src=$DRILL_SOURCE_SERVER
else
  names=$(az postgres flexible-server list -g "$rg" --query "[?!contains(name, '-drill-')].name" -o tsv 2> "$err") \
    || { echo "::error::could not list the PostgreSQL servers ($(code))"; exit 1; }
  names=$(tr -d '\r' <<< "$names" | grep -v '^$' || true)
  [[ -n "$names" && $(wc -l <<< "$names") -eq 1 ]] || { echo "::error::expected exactly one source PostgreSQL server in the resource group"; exit 1; }
  src=$names
fi
[[ "$src" =~ ^[a-z0-9-]{3,63}$ ]] || { echo "::error::the source server name is not valid"; exit 1; }

left=$(az postgres flexible-server list -g "$rg" --query "[?contains(name, '-drill-')].name" -o tsv 2> "$err") \
  || { echo "::error::could not list the PostgreSQL servers ($(code))"; exit 1; }
if [[ -n "$(tr -d '\r\n' <<< "$left")" ]]; then
  echo "::error::a drill server from an earlier run still exists in the resource group; delete it first (it bills)"; exit 1
fi

sku=$(az postgres flexible-server show -g "$rg" -n "$src" --query "sku.name" -o tsv 2> "$err" | tr -d '\r') \
  || { echo "::error::could not read the source server ($(code))"; exit 1; }
if [[ "$sku" != Standard_B1ms && "${DRILL_ALLOW_SKU:-0}" != 1 ]]; then
  echo "::error::the source is not Standard_B1ms; the restore keeps its size and would cost more (DRILL_ALLOW_SKU=1 to accept)"; exit 1
fi

admins=$(az postgres flexible-server microsoft-entra-admin list -g "$rg" -s "$src" \
  --query "[?principalType=='User'] | [0].[objectId, principalName]" -o tsv 2> "$err" | tr -d '\r') \
  || { echo "::error::could not read the Entra administrators of the source ($(code))"; exit 1; }
admin_oid=${DRILL_ADMIN_OBJECT_ID:-$(cut -f1 <<< "$admins")}
pg_user=${DRILL_PG_USER:-$(cut -f2 <<< "$admins")}
[[ "$admin_oid" =~ ^[0-9a-fA-F-]{36}$ && -n "$pg_user" && "$pg_user" != None ]] \
  || { echo "::error::no break-glass administrator of type User found; set DRILL_ADMIN_OBJECT_ID and DRILL_PG_USER"; exit 1; }

my_ip=${DRILL_MY_IP:-$(curl -s --max-time 15 https://api.ipify.org 2> /dev/null || true)}
[[ "$my_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { echo "::error::could not determine this machine's IPv4 address (set DRILL_MY_IP)"; exit 1; }

say "Drill: ${env_name}, restore point ${minutes} minutes ago, keep=${keep}"

# ---- psql helpers ----------------------------------------------------------------------------------------------
token() {
  local t
  t=$(az account get-access-token --resource-type oss-rdbms --query accessToken -o tsv 2> /dev/null | tr -d '\r') || return 2
  [[ -n "$t" ]] || return 2
  printf '%s' "$t"
}
# q <host> <database> <sql>: one read-only query, value only; connection details and errors are never printed.
q() {
  local t
  t=$(token) || return 2
  PGPASSWORD="$t" PGCONNECT_TIMEOUT=20 PGSSLMODE="$sslmode" PGOPTIONS="-c default_transaction_read_only=on" \
    psql -X -w -q -At -v ON_ERROR_STOP=1 -h "$1" -p 5432 -U "$pg_user" -d "$2" -c "$3" 2> /dev/null < /dev/null
}
rolepre=""
[[ -n "${DRILL_SET_ROLE:-}" ]] && { [[ "$DRILL_SET_ROLE" =~ ^[a-z_][a-z0-9_]{0,62}$ ]] || { echo "::error::DRILL_SET_ROLE is not a role name"; exit 64; }; rolepre="set role ${DRILL_SET_ROLE}; "; }

# ---- expected migration from the source (optional) -------------------------------------------------------------
if [[ -z "$expected" ]]; then
  az postgres flexible-server firewall-rule create -g "$rg" -s "$src" -n "$rule" --start-ip-address "$my_ip" --end-ip-address "$my_ip" -o none > /dev/null 2> "$err" \
    || { echo "::error::could not open the temporary firewall rule on the source ($(code))"; exit 1; }
  src_rule_open=1
  src_host=$(az postgres flexible-server show -g "$rg" -n "$src" --query fullyQualifiedDomainName -o tsv 2> /dev/null | tr -d '\r') || src_host=""
  src_db=${DRILL_DATABASE:-}
  for ((i = 1; i <= tries; i++)); do
    if [[ -z "$src_db" ]]; then
      src_db=$(q "$src_host" postgres "select datname from pg_database where datname not in ('postgres','template0','template1','azure_maintenance','azure_sys')" | head -2 | paste -sd, -) || src_db=""
      [[ "$src_db" =~ ^[A-Za-z0-9_]+$ ]] || src_db=""
    fi
    if [[ -n "$src_db" ]] && expected=$(q "$src_host" "$src_db" "${rolepre}select max(version) from migrations.schema_migrations") && [[ -n "$expected" ]]; then break; fi
    expected=""; sleep "$retry_s"
  done
  [[ -n "$expected" ]] || { echo "::error::could not read the expected migration version from the source; pass --expected-migration"; exit 1; }
  az postgres flexible-server firewall-rule delete -g "$rg" -s "$src" -n "$rule" --yes -o none > /dev/null 2> "$err" \
    && src_rule_open=0
  say "Expected migration read from the source: ${expected}"
else
  say "Expected migration: ${expected}"
fi

# ---- 2. restore ------------------------------------------------------------------------------------------------
restore_time=$(date -u -d "-${minutes} minutes" +%Y-%m-%dT%H:%M:%S+00:00)
say "Restoring to a new temporary server (this takes several minutes)"
t0=$(now)
created=1   # from here on the trap looks for the server, whatever the restore returns
rc=0
az postgres flexible-server restore -g "$rg" --name "$tmp_name" --source-server "$src" --restore-time "$restore_time" -o none > /dev/null 2> "$err" || rc=$?
(( rc == 0 )) || { echo "::error::the restore failed (${rc}, $(code))"; exit 1; }

# ---- 3. wait for Ready -----------------------------------------------------------------------------------------
deadline=$(( SECONDS + ready_timeout )); state=""
while :; do
  state=$(az postgres flexible-server show -g "$rg" -n "$tmp_name" --query state -o tsv 2> /dev/null | tr -d '\r') || state=""
  [[ "$state" == Ready ]] && break
  (( SECONDS < deadline )) || { echo "::error::the temporary server was not Ready within ${ready_timeout}s"; exit 1; }
  sleep "$poll_s"
done
t_ready=$(now)
say "Restore until Ready: $(( t_ready - t0 )) s"

# ---- 4. administrator and firewall rule, on the temporary server only ------------------------------------------
host=$(az postgres flexible-server show -g "$rg" -n "$tmp_name" --query fullyQualifiedDomainName -o tsv 2> /dev/null | tr -d '\r') || host=""
[[ -n "$host" ]] || { echo "::error::could not read the address of the temporary server"; exit 1; }
az postgres flexible-server microsoft-entra-admin create -g "$rg" -s "$tmp_name" -u "$pg_user" -i "$admin_oid" -t User -o none > /dev/null 2> "$err" \
  || { echo "::error::could not add the break-glass administrator to the temporary server ($(code))"; exit 1; }
az postgres flexible-server firewall-rule create -g "$rg" -s "$tmp_name" -n "$rule" --start-ip-address "$my_ip" --end-ip-address "$my_ip" -o none > /dev/null 2> "$err" \
  || { echo "::error::could not open the firewall rule on the temporary server ($(code))"; exit 1; }

# ---- 5. read-only checks ---------------------------------------------------------------------------------------
db=${DRILL_DATABASE:-}; connected=0
for ((i = 1; i <= tries; i++)); do
  if [[ -z "$db" ]]; then
    d=$(q "$host" postgres "select datname from pg_database where datname not in ('postgres','template0','template1','azure_maintenance','azure_sys')" | head -2 | paste -sd, -) || d=""
    [[ "$d" =~ ^[A-Za-z0-9_]+$ ]] && db=$d
  fi
  if [[ -n "$db" ]] && q "$host" "$db" "select 1" > /dev/null; then connected=1; break; fi
  sleep "$retry_s"
done
(( connected == 1 )) || { echo "::error::could not sign in to the temporary server with an Entra token (administrator not yet active, no route, or the database is not unique)"; exit 1; }
t_conn=$(now)
say "Restore until first successful sign-in (RTO of this drill): $(( t_conn - t0 )) s"

count() { # label table minimum
  local n
  if n=$(q "$host" "$db" "${rolepre}select count(*) from $2") && [[ "$n" =~ ^[0-9]+$ ]]; then
    if (( n >= $3 )); then say "PASS: $1 = ${n} (minimum $3)"; else bad "$1 = ${n}, expected at least $3"; fi
  else
    bad "$1 could not be counted"
  fi
}
count "jobs" public.jobs "$min_jobs"
count "app_users" public.app_users "$min_users"
count "scan_run" public.scan_run "$min_scans"
count "applied migrations" migrations.schema_migrations 1
got=$(q "$host" "$db" "${rolepre}select max(version) from migrations.schema_migrations") || got=""
if [[ -z "$got" ]]; then bad "the highest migration could not be read"
elif [[ "$got" == "$expected" ]]; then say "PASS: highest migration = ${got}"
else bad "highest migration is ${got}, expected ${expected} (a migration that ran after the restore point shows up here: use a smaller --minutes-ago)"; fi

say "Timings: restore until Ready $(( t_ready - t0 )) s, until sign-in $(( t_conn - t0 )) s, checks $(( $(now) - t_conn )) s"
if (( fail == 0 )); then say "Restore drill PASSED"; else say "Restore drill FAILED"; exit 1; fi
