#!/usr/bin/env bash
# One entry point for every Terraform call in the workflows, so each layer always gets the same directory,
# var files, output rules and locking:
#   plan        lock-free (the tf-plan identity may only read state), exit 0 = no changes, 2 = changes
#   apply-plan  plan with the state lock, writes tfplan (apply identities only)
#   apply       applies tfplan with the state lock
#   verify      second plan after an apply, exit 0 = no changes, 2 = changes
#   summary     per-type summary of tfplan (scripts/plan_summary.py)
# Usage: bash scripts/tf-layer.sh <command> <platform|staging|nettest|identity-staging>
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

q() { local sub=$1; shift; bash "$root/scripts/tf-quiet.sh" "$mode" -chdir="$dir" "$sub" -no-color "$@"; }

case "$cmd" in
  init)
    q init -input=false \
      -backend-config="resource_group_name=${TF_STATE_RG:?}" \
      -backend-config="storage_account_name=${TF_STATE_SA:?}" ;;
  plan)       TF_QUIET_OK_CODES="0 2" q plan -input=false -lock=false -detailed-exitcode -out=tfplan "${vars[@]}" ;;
  apply-plan) q plan -input=false -lock-timeout=5m -out=tfplan "${vars[@]}" ;;
  apply)      q apply -input=false -lock-timeout=5m tfplan ;;
  verify)     TF_QUIET_OK_CODES="0 2" q plan -input=false -lock-timeout=5m -detailed-exitcode "${vars[@]}" ;;
  summary)    terraform -chdir="$dir" show -json tfplan 2> /dev/null | python3 "$root/scripts/plan_summary.py" ;;
  *) echo "::error::unknown command ${cmd}"; exit 2 ;;
esac
