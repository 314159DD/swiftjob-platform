#!/usr/bin/env bash
# One entry point for every Terraform call in the workflows, so each layer always gets the same directory,
# var files, output rules and locking:
#   plan        lock-free (the tf-plan identity may only read state), exit 0 = no changes, 2 = changes
#   apply-plan  plan with the state lock, writes tfplan (apply identities only)
#   apply       applies tfplan with the state lock
#   verify      second plan after an apply, exit 0 = no changes, 2 = changes
#   summary     per-type summary of tfplan (scripts/plan_summary.py)
#   guard       fails when tfplan deletes or replaces the PostgreSQL server, storage account or Key Vault (scripts/prod-guard.py)
#   migrate-plan   plan for the db-migrate job only (-target), with the state lock, writes tfplan-db
#   migrate-check  exit 0 only if the db-migrate job address is in tfplan-db (or in the state). A -target that matches nothing
#                  plans "No changes" and exits 0, so without this check a wrong address would silently run the OLD image.
#   migrate-apply  applies tfplan-db. scripts/db-migrate.sh uses both so the job runs the new image before the app update.
#                  A plan written before this apply is stale afterwards: plan again (apply-plan) before the full apply.
# Usage: bash scripts/tf-layer.sh <command> <platform|staging|prod|nettest|identity-staging|identity-prod>
set -euo pipefail
cmd=${1:?command}
layer=${2:?layer}
root="$(cd "$(dirname "$0")/.." && pwd)"
vars=()
case "$layer" in
  platform) dir="$root/platform"; mode=redact ;;
  # Every layer except platform fails closed: it may be fed from private inputs, so Terraform's stderr is never printed.
  nettest)  dir="$root/environments/nettest"; mode=suppress ;;
  staging)
    dir="$root/environments/staging"; mode=suppress
    cfg="${CONFIG_DIR:-$root/config}/staging"
    if [[ ! -f "$cfg/terraform.tfvars" ]]; then
      echo "::error::private configuration for ${layer} not found"; exit 2
    fi
    vars+=("-var-file=$cfg/terraform.tfvars")
    if [[ -f "$cfg/images.auto.tfvars.json" ]]; then vars+=("-var-file=$cfg/images.auto.tfvars.json"); fi
    ;;
  prod)
    # Same module as staging, own state key in the prod container, own pipeline identity (swiftjob-tf-prod, ADR 12).
    dir="$root/environments/prod"; mode=suppress
    cfg="${CONFIG_DIR:-$root/config}/prod"
    if [[ ! -f "$cfg/terraform.tfvars" ]]; then
      echo "::error::private configuration for ${layer} not found"; exit 2
    fi
    vars+=("-var-file=$cfg/terraform.tfvars")
    if [[ -f "$cfg/images.auto.tfvars.json" ]]; then vars+=("-var-file=$cfg/images.auto.tfvars.json"); fi
    ;;
  identity-prod)
    dir="$root/environments/identity-prod"; mode=suppress
    cfg="${CONFIG_DIR:-$root/config}/prod"
    if [[ ! -f "$cfg/identity.auto.tfvars" ]]; then
      echo "::error::private configuration for ${layer} not found"; exit 2
    fi
    vars+=("-var-file=$cfg/identity.auto.tfvars")
    ;;
  identity-staging)
    # Customer identity (external tenant) registrations. Only ids and URLs come from the private configuration.
    dir="$root/environments/identity-staging"; mode=suppress
    cfg="${CONFIG_DIR:-$root/config}/staging"
    if [[ ! -f "$cfg/identity.auto.tfvars" ]]; then
      echo "::error::private configuration for ${layer} not found"; exit 2
    fi
    vars+=("-var-file=$cfg/identity.auto.tfvars")
    ;;
  *) echo "::error::unknown layer ${layer}"; exit 2 ;;
esac

# The one resource a migrate-first deploy changes ahead of the rest (same address in every workload layer).
DB_JOB_TARGET='module.workload.azurerm_container_app_job.this["db-migrate"]'

q() { local sub=$1; shift; bash "$root/scripts/tf-quiet.sh" "$mode" -chdir="$dir" "$sub" -no-color "$@"; }

case "$cmd" in
  init)
    q init -input=false \
      -backend-config="resource_group_name=${TF_STATE_RG:?}" \
      -backend-config="storage_account_name=${TF_STATE_SA:?}" ;;
  plan)       TF_QUIET_OK_CODES="0 2" q plan -input=false -lock=false -detailed-exitcode -out=tfplan "${vars[@]}" ;;
  apply-plan) q plan -input=false -lock-timeout=5m -out=tfplan "${vars[@]}" ;;
  apply)      q apply -input=false -lock-timeout=5m tfplan ;;
  migrate-plan)  q plan -input=false -lock-timeout=5m -target="$DB_JOB_TARGET" -out=tfplan-db "${vars[@]}" ;;
  migrate-check)
    # Fixed messages only: nothing from the plan or the state is printed.
    if terraform -chdir="$dir" show -json tfplan-db 2> /dev/null | TARGET="$DB_JOB_TARGET" python3 -c '
import json, os, sys
d = json.load(sys.stdin)
t = os.environ["TARGET"]
rc = d.get("resource_changes") or []
sys.exit(0 if any(r.get("address") == t for r in rc) else 1)' 2> /dev/null; then
      echo "migrate target found in the plan"
    elif terraform -chdir="$dir" state list 2> /dev/null | grep -qxF -- "$DB_JOB_TARGET"; then
      echo "migrate target found in the state"
    else
      echo "::error::the db-migrate job address is in neither the targeted plan nor the state"; exit 1
    fi ;;
  migrate-apply) q apply -input=false -lock-timeout=5m tfplan-db ;;
  verify)     TF_QUIET_OK_CODES="0 2" q plan -input=false -lock-timeout=5m -detailed-exitcode "${vars[@]}" ;;
  summary)    terraform -chdir="$dir" show -json tfplan 2> /dev/null | python3 "$root/scripts/plan_summary.py" ;;
  # Delete guard (prod layer, ADR 12): fails when tfplan deletes or replaces the database, storage account or Key Vault.
  guard)      terraform -chdir="$dir" show -json tfplan 2> /dev/null | python3 "$root/scripts/prod-guard.py" ;;
  *) echo "::error::unknown command ${cmd}"; exit 2 ;;
esac
