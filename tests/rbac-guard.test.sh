#!/usr/bin/env bash
# Tests for scripts/rbac-guard.sh. Run: bash tests/rbac-guard.test.sh
set -euo pipefail
script="$(cd "$(dirname "$0")/.." && pwd)/scripts/rbac-guard.sh"
fail=0
PIPE=11111111-aaaa-bbbb-cccc-000000000001
HUMAN=99999999-aaaa-bbbb-cccc-000000000009
MG=/providers/Microsoft.Management/managementGroups/mg-platform
expect() { # name expected-exit expected-text json
  local out rc=0
  out=$(printf '%s' "$4" | bash "$script" "$PIPE" 2>&1) || rc=$?
  if [[ "$rc" == "$2" && "$out" == *"$3"* ]]; then echo "ok   $1"; else echo "FAIL $1 -> $rc '$out'"; fail=1; fi
}
expect "clean" 0 "rbac guard passed" "[{\"principalId\":\"$PIPE\",\"roleDefinitionName\":\"Reader\",\"scope\":\"$MG\",\"condition\":null}]"
expect "empty list" 0 "rbac guard passed" "[]"
expect "owner at management group" 1 "::error::11111111 holds Owner at $MG" "[{\"principalId\":\"$PIPE\",\"roleDefinitionName\":\"Owner\",\"scope\":\"$MG\",\"condition\":null}]"
expect "user access administrator" 1 "holds User Access Administrator at" "[{\"principalId\":\"$PIPE\",\"roleDefinitionName\":\"User Access Administrator\",\"scope\":\"$MG\",\"condition\":null}]"
W="ActionMatches{'Microsoft.Authorization/roleAssignments/write'}"; D="ActionMatches{'Microsoft.Authorization/roleAssignments/delete'}"
PLAT="92aaf0da-9dab-42b6-94a3-d43ce8d16293, 749f88d5-cbae-40b8-bcfc-e573ddc772fa"
APP="4633458b-17de-408a-b874-0445c86b69e6, ba92f5b4-2d11-453d-a403-e96b0029c9fe, 2a2b9908-6ea1-4ae2-8e65-a410df84e7d1, 3913510d-42f4-4e42-8a64-420c390055eb, 5e5e5e5e-0000-0000-0000-000000000000"
T="Microsoft.Authorization/roleAssignments:PrincipalType] StringEqualsIgnoreCase 'ServicePrincipal'"
rbac() { printf '[{"principalId":"%s","roleDefinitionName":"Role Based Access Control Administrator","scope":"%s","condition":"%s"}]' "$PIPE" "$MG" "$1"; }
expect "platform condition intact" 0 "rbac guard passed" "$(rbac "$W $D GuidEquals {$PLAT}")"
expect "staging condition intact" 0 "rbac guard passed" "$(rbac "$W $D GuidEquals {$APP} $T")"
expect "staging condition without the PrincipalType clause" 1 "holds Role Based Access Control Administrator at" "$(rbac "$W $D GuidEquals {$APP}")"
expect "staging condition missing a role GUID" 1 "holds Role Based Access Control Administrator at" "$(rbac "$W $D GuidEquals {${APP/4633458b-17de-408a-b874-0445c86b69e6, /}} $T")"
expect "platform condition without the delete clause" 1 "holds Role Based Access Control Administrator at" "$(rbac "$W GuidEquals {$PLAT}")"
expect "trivial condition" 1 "holds Role Based Access Control Administrator at" "$(rbac "true")"
expect "rbac admin without condition" 1 "holds Role Based Access Control Administrator at" "[{\"principalId\":\"$PIPE\",\"roleDefinitionName\":\"Role Based Access Control Administrator\",\"scope\":\"$MG\",\"condition\":null}]"
expect "rbac admin empty condition" 1 "holds Role Based Access Control Administrator at" "[{\"principalId\":\"$PIPE\",\"roleDefinitionName\":\"Role Based Access Control Administrator\",\"scope\":\"$MG\",\"condition\":\"\"}]"
expect "human owner is fine" 0 "rbac guard passed" "[{\"principalId\":\"$HUMAN\",\"roleDefinitionName\":\"Owner\",\"scope\":\"$MG\",\"condition\":null}]"
exit $fail
