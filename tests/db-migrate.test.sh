#!/usr/bin/env bash
# Tests for scripts/db-migrate.sh with a stub az and a stub tf-layer.sh. Run: bash tests/db-migrate.test.sh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
check() { if [[ "$1" == "$2" ]]; then echo "ok   $3"; else echo "FAIL $3 (expected '$2', got '$1')"; fail=1; fi; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"
cat > "$tmp/bin/az" <<'STUB'
#!/usr/bin/env bash
# AZ_JOB: present | missing | error ; AZ_START: ok | fail | noname ; AZ_STATUSES: space-separated answers of execution show,
# the last one repeats ; AZ_SHOW_FAIL=1: every execution show fails. Calls are logged to AZ_LOG.
echo "$*" >> "$AZ_LOG"
case "$*" in
  "extension show"*) exit 0 ;;
  "containerapp job show"*)
    case "${AZ_JOB:-present}" in
      present) echo job-x ;;
      missing) echo "ERROR: (ResourceNotFound) The Resource 'Microsoft.App/jobs/job-staging-db-migrate' under resource group 'rg-x' was not found." >&2; exit 3 ;;
      error) echo "(AuthorizationFailed) /subscriptions/SECRET-ID" >&2; exit 1 ;;
    esac ;;
  "containerapp job start"*)
    case "${AZ_START:-ok}" in
      ok) printf 'job-staging-db-migrate-abc123\r\n' ;;
      noname) exit 0 ;;
      fail) echo "(Forbidden) /subscriptions/SECRET-ID" >&2; exit 1 ;;
    esac ;;
  "containerapp job execution show"*)
    [[ "${AZ_SHOW_FAIL:-0}" == 1 ]] && { echo "boom SECRET-ID" >&2; exit 1; }
    n=$(cat "$AZ_STATE" 2>/dev/null || echo 0); echo $((n + 1)) > "$AZ_STATE"
    read -ra a <<< "$AZ_STATUSES"; i=$n; (( i >= ${#a[@]} )) && i=$(( ${#a[@]} - 1 )); printf '%s\r\n' "${a[$i]}" ;;
esac
STUB
cat > "$tmp/tf-layer.sh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$TF_LOG"
STUB
chmod +x "$tmp/bin/az" "$tmp/tf-layer.sh"
export PATH="$tmp/bin:$PATH" TF_LAYER="$tmp/tf-layer.sh" AZ_LOG="$tmp/az.log" AZ_STATE="$tmp/state" TF_LOG="$tmp/tf.log"
export DB_MIGRATE_POLL_S=0 DB_MIGRATE_TIMEOUT_S=3 GITHUB_OUTPUT="$tmp/out" GITHUB_STEP_SUMMARY="$tmp/summary"
run() { : > "$AZ_LOG"; : > "$TF_LOG"; : > "$GITHUB_OUTPUT"; rm -f "$AZ_STATE"; rc=0; out=$(env "$@" bash "$root/scripts/db-migrate.sh" ${ARGS:-staging} 2>&1) || rc=$?; }

run AZ_STATUSES="Running Running Succeeded"
check "$rc" 0 "Succeeded after Running passes"
check "$(tr '\n' '|' < "$TF_LOG")" "migrate-plan staging|migrate-apply staging|" "the job is updated through the targeted plan and apply, in that order"
check "$(grep -c 'execution show' "$AZ_LOG")" 3 "it polls until the end"

run AZ_STATUSES="Running Failed"
check "$rc" 1 "Failed fails the step"
check "$(grep -c 'ended as Failed' <<< "$out")" 1 "the failure is named"

run AZ_STATUSES="Stopped"
check "$rc" 1 "Stopped fails the step"

run AZ_STATUSES="Running"
check "$rc" 1 "a run that never ends times out"
check "$(grep -c 'did not finish within' <<< "$out")" 1 "the timeout is named"

run AZ_STATUSES="Succeeded" AZ_START=fail
check "$rc" 1 "a failed start fails the step"
check "$(grep -c 'SECRET-ID' <<< "$out" || true)" 0 "az error text is not printed"
check "$(grep -c 'Forbidden' <<< "$out")" 1 "an allowlisted error code is printed"

run AZ_STATUSES="Succeeded" AZ_START=noname
check "$rc" 1 "a start without an execution name fails the step"

run AZ_SHOW_FAIL=1 AZ_STATUSES=x
check "$rc" 1 "a persistent read failure fails the step"
check "$(grep -c 'SECRET-ID' <<< "$out" || true)" 0 "read errors are not printed"

run AZ_JOB=error AZ_STATUSES=Succeeded
check "$rc" 1 "an unreadable job fails the step"
check "$(grep -c 'SECRET-ID' <<< "$out" || true)" 0 "show errors are not printed"

run AZ_JOB=missing AZ_STATUSES=Succeeded
check "$rc" 0 "a missing job defers"
check "$(cat "$GITHUB_OUTPUT")" "deferred=true" "the deferral is an output"
check "$(wc -c < "$TF_LOG" | tr -d ' ')" 0 "nothing is applied when deferring"
check "$(grep -c 'job start' "$AZ_LOG" || true)" 0 "nothing is started when deferring"

ARGS="staging run-only" run AZ_STATUSES="Succeeded"
check "$rc" 0 "run-only runs the job"
check "$(wc -c < "$TF_LOG" | tr -d ' ')" 0 "run-only does not touch Terraform"
ARGS="staging run-only" run AZ_JOB=missing AZ_STATUSES="Succeeded"
check "$rc" 1 "run-only fails when the job is still missing"

ARGS="prod" run AZ_STATUSES="Succeeded"
check "$(grep -c -- '-g rg-swiftjob-prod -n job-prod-db-migrate' "$AZ_LOG" | head -1)" "$(grep -c 'job' "$AZ_LOG" | head -1)" "prod uses its own job and resource group"
ARGS="dev" run AZ_STATUSES="Succeeded"
check "$rc" 64 "unknown environments are refused"

exit "$fail"
