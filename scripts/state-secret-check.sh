#!/usr/bin/env bash
# Usage: state-secret-check.sh <layer>   (needs an initialised layer and read access to its state)
# Fails when any container app or job keeps a secret with an inline value in the Terraform state, and when it
# could not inspect anything (no state, no resources, or a container app or job without a secret attribute).
# A state with resources but no container app or job (apps_enabled = false) has nothing to check and passes.
# Scope: only the secret entries of container apps and jobs. A count of 0 says nothing about other material the
# state may hold (for example storage account keys). Prints two count lines and nothing from the state itself.
set -euo pipefail
layer=${1:?usage: state-secret-check.sh <layer>}
root="$(cd "$(dirname "$0")/.." && pwd)"
case "$layer" in
  staging) dir="$root/environments/staging" ;;
  *) echo "::error::state-secret-check.sh: unknown layer ${layer}" >&2; exit 2 ;;
esac
state=$(mktemp); trap 'rm -f "$state"' EXIT
terraform -chdir="$dir" state pull > "$state" 2> /dev/null || { echo "::error::could not read the state of ${layer}" >&2; exit 1; }
# Prints "<resources> <inspected> <with value> <missing attribute>".
counts=$(python3 -c '
import json, sys
inspected = bad = missing = 0
resources = json.load(open(sys.argv[1])).get("resources", [])
for r in resources:
    if r.get("type") in ("azurerm_container_app", "azurerm_container_app_job"):
        for i in r.get("instances", []):
            inspected += 1
            attrs = i.get("attributes", {})
            if "secret" not in attrs:
                missing += 1
            for s in attrs.get("secret") or []:
                if s.get("value"):
                    bad += 1
print(len(resources), inspected, bad, missing)
' "$state") || { echo "::error::could not parse the state of ${layer}" >&2; exit 1; }
read -r total inspected bad missing <<< "$counts"
echo "container apps and jobs inspected: ${inspected}"
echo "secret entries with a value: ${bad}"
if [[ "$total" == 0 ]]; then echo "::error::the state of ${layer} is empty, nothing was inspected" >&2; exit 1; fi
if [[ "$inspected" == 0 ]]; then echo "No container apps or jobs in the state yet, nothing to check"; exit 0; fi
if [[ "$missing" != 0 ]]; then echo "::error::${missing} container app or job entries have no secret attribute, the state format may have changed" >&2; exit 1; fi
[[ "$bad" == 0 ]]
