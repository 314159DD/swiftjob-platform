#!/usr/bin/env bash
# Moves a subscription under a management group. Run by the owner: moving subscriptions between management
# groups changes which policies apply to everything in them, so it is not a pipeline permission.
# Usage: bash scripts/move-subscription.sh <subscription-id> <management-group-name>
set -euo pipefail
export MSYS_NO_PATHCONV=1
SUB=${1:?subscription id}
MG=${2:?management group name}
az account management-group subscription add --name "$MG" --subscription "$SUB"
az account management-group subscription show --name "$MG" --subscription "$SUB" --query "{sub:displayName,parent:parent.id}" -o json
