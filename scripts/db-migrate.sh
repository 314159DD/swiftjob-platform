#!/usr/bin/env bash
# Runs the database migrations of one environment BEFORE the app update, and fails the deploy unless they succeed.
# Usage: bash scripts/db-migrate.sh <staging|prod> [run-only]      (needs a signed-in az; full mode also needs terraform)
#
#   full      1. terraform apply -target on the db-migrate job only (scripts/tf-layer.sh migrate-plan/migrate-apply), so the
#                job runs the new image; 2. start one execution; 3. poll it until it ends.
#   run-only  steps 2 and 3 (after the first apply created the job, see "deferred" below).
#
# Policy: expand/contract. The old app code keeps serving while this runs, and keeps serving if a later step of the
# deploy fails, so every migration must work with the app code that is running right now: additive changes first
# (new table, new nullable column, new index), and a drop or rename only in a later release, after no deployed code
# uses the old shape. See the backend repository, db/migrations/README.md.
#
# Why -target and not an image override on `az containerapp job start`: the digest then comes from Terraform's own inputs
# (nothing parsed out of the private configuration), the job's recorded image is the image that ran, and the later full
# plan has no leftover difference for the job. The price is a partial apply of that one resource (and its dependencies,
# which are unchanged in normal operation). The caller must plan again afterwards, because the state moved.
#
# Why it always runs, also when the digest is unchanged: the migrations are idempotent, and "unchanged" does not mean
# "ran successfully" (a previous deploy can have updated the job and then failed in the migration). It costs about a minute.
#
# Why the execution status and not the JOB_RESULT line in Log Analytics: db.migrate exits 1 on any failure, and the
# execution ends Failed then, so the status is the same answer without the ingestion delay of several minutes.
#
# Output: fixed messages only. az errors are never printed (they quote resource IDs and principal IDs); only an Azure
# error code from a short allowlist is. The digest, the execution name and resource IDs are never printed.
# Without the job (first deploy of an environment) the full mode defers: it writes deferred=true to GITHUB_OUTPUT and
# the workflow calls run-only after the apply that creates the job.
# Env: DB_MIGRATE_TIMEOUT_S (default 1200, the job's replica_timeout is 900 and image pull and start count against it), DB_MIGRATE_POLL_S (default 10), DB_MIGRATE_RG, TF_LAYER (test hook).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
env_name=${1:-}; mode=${2:-full}
case "$env_name" in staging|prod) ;; *) echo "::error::usage: db-migrate.sh <staging|prod> [run-only]"; exit 64 ;; esac
case "$mode" in full|run-only) ;; *) echo "::error::unknown mode"; exit 64 ;; esac
rg=${DB_MIGRATE_RG:-rg-swiftjob-${env_name}}
job="job-${env_name}-db-migrate"
timeout_s=${DB_MIGRATE_TIMEOUT_S:-1200}; poll_s=${DB_MIGRATE_POLL_S:-10}
tf_layer=${TF_LAYER:-$root/scripts/tf-layer.sh}
die() { echo "::error::database migration: $1"; exit 1; }
err=$(mktemp); trap 'rm -f "$err"' EXIT
# At most one allowlisted Azure error code from the last failed az call.
code() { { grep -oE '\((AuthorizationFailed|ResourceNotFound|ResourceGroupNotFound|Forbidden|Conflict|ContainerAppJobExecutionNotFound|InvalidAuthenticationToken|ExpiredAuthenticationToken)\)' "$err" || true; } | head -1 | tr -d '()'; }

if ! az extension show --name containerapp > /dev/null 2>&1; then
  az extension add --name containerapp --yes --only-show-errors > /dev/null 2>&1 || die "could not install the containerapp az extension"
fi

# Prints "yes" or "no"; any other failure ends the step.
job_exists() {
  local rc=0
  az containerapp job show -g "$rg" -n "$job" --query name -o tsv > /dev/null 2> "$err" || rc=$?
  if (( rc == 0 )); then echo yes; return; fi
  if grep -qE "\(ResourceNotFound\).*jobs/${job}'" "$err"; then echo no; return; fi
  die "could not read the job (${rc}, $(code))"
}

exists=$(job_exists)
if [[ "$exists" == no ]]; then
  if [[ "$mode" == run-only ]]; then die "the migration job does not exist after the apply"; fi
  echo "Migration job not deployed yet: the migration runs after the apply that creates it"
  echo "deferred=true" >> "${GITHUB_OUTPUT:-/dev/null}"
  exit 0
fi

if [[ "$mode" == full ]]; then
  echo "Updating the migration job to the new image"
  bash "$tf_layer" migrate-plan "$env_name"
  # A -target that matches nothing plans "No changes" and exits 0: the job would then run the OLD image.
  bash "$tf_layer" migrate-check "$env_name" || die "the targeted plan does not contain the migration job"
  bash "$tf_layer" migrate-apply "$env_name"
fi

rc=0
exec_name=$(az containerapp job start -g "$rg" -n "$job" --query name -o tsv 2> "$err") || rc=$?
exec_name=$(tr -d '\r' <<< "$exec_name")
(( rc == 0 )) || die "could not start the job (${rc}, $(code))"
[[ "$exec_name" =~ ^[A-Za-z0-9._-]+$ ]] || die "the job start returned no execution name"
echo "Migration started, waiting for it to finish (timeout ${timeout_s}s)"

deadline=$(( SECONDS + timeout_s )); read_errors=0
while :; do
  rc=0
  status=$(az containerapp job execution show -g "$rg" -n "$job" --job-execution-name "$exec_name" \
    --query properties.status -o tsv 2> "$err") || rc=$?
  status=$(tr -d '\r' <<< "$status")
  if (( rc != 0 )); then
    # A single failed read (token, network) must not fail the deploy; a persistent one must.
    read_errors=$(( read_errors + 1 ))
    (( read_errors < 5 )) || die "cannot read the execution status (${rc}, $(code))"
  else
    read_errors=0
    case "$status" in
      Succeeded) echo "Database migration: Succeeded" | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"; exit 0 ;;
      Failed|Stopped|Degraded) die "the migration ended as ${status}; read the job's console logs in Azure (log analytics, JOB_RESULT line)" ;;
      Running|Processing|"") ;;   # still going; an unknown value is treated the same until the deadline
    esac
  fi
  if (( SECONDS >= deadline )); then
    [[ "$status" =~ ^[A-Za-z]{1,20}$ ]] || status=unknown
    # Do not leave a half-run migration behind (the later retry would run next to it). Output is discarded; at most
    # one allowlisted error code is named.
    stop_rc=0
    az containerapp job stop -g "$rg" -n "$job" --job-execution-name "$exec_name" > /dev/null 2> "$err" || stop_rc=$?
    if (( stop_rc != 0 )); then echo "::warning::could not stop the timed-out execution (${stop_rc}, $(code))"; fi
    die "the migration did not finish within ${timeout_s}s (last status: ${status})"
  fi
  sleep "$poll_s"
done
