#!/usr/bin/env bash
# Removes every probe firewall rule (name prefix access-test-) from the PostgreSQL server of the environment.
# The access test removes its own rule; this runs after it (also after cancellation or a crash) as the second line
# of defence. A failed list or delete fails the step. Prints fixed text only.
# Usage: bash scripts/access-test-cleanup.sh <resource-group>
set -euo pipefail
export MSYS_NO_PATHCONV=1
RG=${1:?resource group}
pg=$(az postgres flexible-server list -g "$RG" --query "[0].name" -o tsv 2> /dev/null) || { echo "FAIL: PostgreSQL server could not be listed"; exit 1; }
pg=$(tr -d '\r' <<< "$pg")
[[ -n "$pg" ]] || { echo "INFO: no PostgreSQL server, nothing to clean up"; exit 0; }
names=$(az postgres flexible-server firewall-rule list -g "$RG" -s "$pg" --query "[?starts_with(name, 'access-test-')].name" -o tsv 2> /dev/null) \
  || { echo "FAIL: firewall rules could not be listed"; exit 1; }
failed=0
while IFS= read -r n; do
  n=$(tr -d '\r' <<< "$n")
  [[ -n "$n" ]] || continue
  if az postgres flexible-server firewall-rule delete -g "$RG" -s "$pg" --name "$n" --yes -o none 2> /dev/null; then
    echo "removed a leftover probe firewall rule"
  else
    echo "FAIL: a probe firewall rule could not be removed"; failed=1
  fi
done <<< "$names"
(( failed == 0 )) || exit 1
echo "no probe firewall rule left"
