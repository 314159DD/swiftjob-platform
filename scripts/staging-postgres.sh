#!/usr/bin/env bash
# Stops or starts the staging PostgreSQL server by hand, to keep it inside the free grant while production runs
# (plan 05 Q3). Azure starts a stopped flexible server again after 7 days. Run by the owner, signed in with az.
# Usage: bash scripts/staging-postgres.sh <stop|start|status>
set -euo pipefail
export MSYS_NO_PATHCONV=1
action=${1:-}
case "$action" in stop|start|status) ;; *) echo "usage: staging-postgres.sh <stop|start|status>" >&2; exit 64 ;; esac
rg=${STAGING_RG:-rg-swiftjob-staging}
name=$(az postgres flexible-server list -g "$rg" --query "[0].name" -o tsv | tr -d '\r')
[[ -n "$name" ]] || { echo "no PostgreSQL server in ${rg}" >&2; exit 1; }
case "$action" in
  status) az postgres flexible-server show -g "$rg" -n "$name" --query state -o tsv ;;
  *) az postgres flexible-server "$action" -g "$rg" -n "$name" -o none && echo "staging PostgreSQL: ${action} requested" ;;
esac
