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
expect "rbac admin with condition" 0 "rbac guard passed" "[{\"principalId\":\"$PIPE\",\"roleDefinitionName\":\"Role Based Access Control Administrator\",\"scope\":\"$MG\",\"condition\":\"((!(ActionMatches{'x'})))\"}]"
expect "rbac admin without condition" 1 "holds Role Based Access Control Administrator at" "[{\"principalId\":\"$PIPE\",\"roleDefinitionName\":\"Role Based Access Control Administrator\",\"scope\":\"$MG\",\"condition\":null}]"
expect "rbac admin empty condition" 1 "holds Role Based Access Control Administrator at" "[{\"principalId\":\"$PIPE\",\"roleDefinitionName\":\"Role Based Access Control Administrator\",\"scope\":\"$MG\",\"condition\":\"\"}]"
expect "human owner is fine" 0 "rbac guard passed" "[{\"principalId\":\"$HUMAN\",\"roleDefinitionName\":\"Owner\",\"scope\":\"$MG\",\"condition\":null}]"
exit $fail
