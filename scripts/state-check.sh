#!/usr/bin/env bash
# Usage: state-check.sh <layer>   (needs TF_STATE_SA and a signed-in az)
# tf-plan only reads, so a layer whose state blob does not exist yet cannot be planned (the backend would write an empty state).
# A missing blob is only acceptable while the layer's resource group is empty.
# Exit: 0 state exists, 3 no state and empty resource group (skip the plan), 1 error or missing state with resources.
set -euo pipefail
layer="${1:?usage: state-check.sh <layer>}"
: "${TF_STATE_SA:?TF_STATE_SA is not set}"
case "$layer" in
  staging) rg="rg-swiftjob-staging" ;;
  *) echo "::error::state-check.sh: no resource group known for layer ${layer}" >&2; exit 1 ;;
esac
exists=$(az storage blob exists --account-name "$TF_STATE_SA" -c "$layer" -n "$layer.tfstate" --auth-mode login --query exists -o tsv | tr -d '\r') || {
  echo "::error::state check for ${layer} failed" >&2; exit 1; }
if [[ "$exists" == "true" ]]; then exit 0; fi
if [[ "$exists" != "false" ]]; then echo "::error::state check for ${layer} returned an unexpected answer" >&2; exit 1; fi
# No state. An unknown resource group counts as empty (not created yet); any other failure is an error.
count=$(az resource list -g "$rg" --query "length(@)" -o tsv 2>/dev/null | tr -d '\r') || count=""
if [[ -z "$count" ]]; then
  if [[ "$(az group exists -n "$rg" -o tsv 2>/dev/null | tr -d '\r')" == "false" ]]; then count=0
  else echo "::error::could not list resources of ${rg}" >&2; exit 1; fi
fi
if [[ ! "$count" =~ ^[0-9]+$ ]]; then echo "::error::unexpected resource count for ${rg}" >&2; exit 1; fi
if [[ "$count" -gt 0 ]]; then
  echo "::error::state for ${layer} is missing but its resource group has resources" >&2; exit 1
fi
echo "::notice::${layer} state not created yet and ${rg} is empty: first apply pending" >&2
exit 3
