#!/usr/bin/env bash
# Fails when a pipeline identity holds a role that could grant itself more access.
# stdin: JSON array like `az role assignment list` (principalId, roleDefinitionName, scope, condition).
# args: forbidden principal IDs. Owner and User Access Administrator are always forbidden for them.
# Role Based Access Control Administrator is allowed only with a condition.
set -euo pipefail
if [[ $# -eq 0 ]]; then echo "usage: rbac-guard.sh <principal-id>... < assignments.json" >&2; exit 2; fi
ids=$(printf '%s\n' "$@" | jq -R . | jq -s .)
bad=$(jq -r --argjson ids "$ids" '
  .[] | select(.principalId as $p | $ids | index($p))
      | select(.roleDefinitionName == "Owner" or .roleDefinitionName == "User Access Administrator"
               or (.roleDefinitionName == "Role Based Access Control Administrator" and ((.condition // "") == "")))
      | "::error::\(.principalId[0:8]) holds \(.roleDefinitionName) at \(.scope)"')
if [[ -n "$bad" ]]; then printf '%s\n' "$bad"; exit 1; fi
echo "rbac guard passed"
