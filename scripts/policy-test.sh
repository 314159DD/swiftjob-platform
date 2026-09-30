#!/usr/bin/env bash
# Proves the enforced policies: every forbidden template must be refused with RequestDisallowedByPolicy by
# ARM validation, and the allowed control template must pass. Validation creates nothing and costs nothing.
# Usage: bash scripts/policy-test.sh <resource-group>
set -euo pipefail
export MSYS_NO_PATHCONV=1
RG=${1:?resource group}
dir="$(cd "$(dirname "$0")/.." && pwd)/tests/policy-test"
fail=0

for t in storage-shared-key wrong-region nat-gateway postgres-large; do
  out=$(az deployment group validate -g "$RG" --template-file "$dir/$t.json" -o none 2>&1) && rc=0 || rc=$?
  if (( rc != 0 )) && grep -q "RequestDisallowedByPolicy" <<< "$out"; then
    echo "PASS: $t refused by policy"
  else
    echo "FAIL: $t was not refused by policy (exit $rc)"; fail=1
  fi
done

if az deployment group validate -g "$RG" --template-file "$dir/allowed-control.json" -o none 2>/dev/null; then
  echo "PASS: allowed-control validates"
else
  echo "FAIL: allowed-control was refused, the test would pass for the wrong reason"; fail=1
fi
exit $fail
