#!/usr/bin/env bash
# Fails when a pipeline identity holds a role that could grant itself more access.
# stdin: JSON array like `az role assignment list` (principalId, roleDefinitionName, scope, condition).
# args: forbidden principal IDs. Owner and User Access Administrator are always forbidden for them.
# Role Based Access Control Administrator is allowed only with a condition, and the condition must still contain the
# expected role GUIDs of one of the two profiles in scripts/abac-expected.sh: tf-platform (write and delete clauses and
# its GUIDs) or tf-staging (the same clauses, its GUIDs and the service-principal-only PrincipalType clause).
set -euo pipefail
# shellcheck source=/dev/null
source "$(dirname "$0")/abac-expected.sh"
if [[ $# -eq 0 ]]; then echo "usage: rbac-guard.sh <principal-id>... < assignments.json" >&2; exit 2; fi
ids=$(printf '%s\n' "$@" | jq -R . | jq -s .)
platform=$(printf '%s\n' "${ABAC_PLATFORM_ROLES[@]}" | jq -R . | jq -s .)
app=$(printf '%s\n' "${ABAC_APP_ROLES[@]}" | jq -R . | jq -s .)
write_clause="ActionMatches{'Microsoft.Authorization/roleAssignments/write'}"
delete_clause="ActionMatches{'Microsoft.Authorization/roleAssignments/delete'}"
type_clause="PrincipalType] StringEqualsIgnoreCase 'ServicePrincipal'"
bad=$(jq -r --argjson ids "$ids" --argjson platform "$platform" --argjson app "$app" \
  --arg w "$write_clause" --arg d "$delete_clause" --arg t "$type_clause" '
  def has_all($c; $guids): all($guids[]; . as $g | $c | ascii_downcase | contains($g | ascii_downcase));
  def intact($c):
    ($c | contains($w)) and ($c | contains($d))
    and (has_all($c; $platform) or (has_all($c; $app) and ($c | contains($t))));
  .[] | select(.principalId as $p | $ids | index($p))
      | select(.roleDefinitionName == "Owner" or .roleDefinitionName == "User Access Administrator"
               or (.roleDefinitionName == "Role Based Access Control Administrator"
                   and (((.condition // "") == "") or (intact(.condition) | not))))
      | "::error::\(.principalId[0:8]) holds \(.roleDefinitionName) at \(.scope)"')
if [[ -n "$bad" ]]; then printf '%s\n' "$bad"; exit 1; fi
echo "rbac guard passed"
