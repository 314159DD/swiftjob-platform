#!/usr/bin/env bash
# Usage: state-secret-check.sh <layer>   (needs an initialised layer and read access to its state)
# Fails when any container app or job keeps a secret with an inline value in the Terraform state.
# Prints one count line and nothing from the state itself.
set -euo pipefail
layer=${1:?usage: state-secret-check.sh <layer>}
root="$(cd "$(dirname "$0")/.." && pwd)"
case "$layer" in
  staging) dir="$root/environments/staging" ;;
  *) echo "::error::state-secret-check.sh: unknown layer ${layer}" >&2; exit 2 ;;
esac
state=$(mktemp); trap 'rm -f "$state"' EXIT
terraform -chdir="$dir" state pull > "$state" 2> /dev/null || { echo "::error::could not read the state of ${layer}" >&2; exit 1; }
n=$(python3 -c '
import json, sys
bad = 0
for r in json.load(open(sys.argv[1])).get("resources", []):
    if r.get("type") in ("azurerm_container_app", "azurerm_container_app_job"):
        for i in r.get("instances", []):
            for s in i.get("attributes", {}).get("secret") or []:
                if s.get("value"):
                    bad += 1
print(bad)
' "$state") || { echo "::error::could not parse the state of ${layer}" >&2; exit 1; }
echo "secret entries with a value: ${n}"
[[ "$n" == 0 ]]
