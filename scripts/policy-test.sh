#!/usr/bin/env bash
# Proves the enforced policies: every forbidden template must be refused with RequestDisallowedByPolicy by
# ARM validation, and the allowed control template must pass. Validation creates nothing and costs nothing.
# Usage: bash scripts/policy-test.sh <resource-group>
set -euo pipefail
export MSYS_NO_PATHCONV=1
RG=${1:?resource group}
dir="$(cd "$(dirname "$0")/.." && pwd)/tests/policy-test"
fail=0

redact() { bash "$(dirname "$0")/redact.sh"; }
first_error() { grep -m1 -E "Code|Message|ERROR" <<< "$1" | redact | cut -c1-300 || true; }

# template:expected policy assignment name
for pair in storage-shared-key:deny-storage-shared-key wrong-region:allowed-locations             nat-gateway:deny-costly-types postgres-large:deny-costly-skus; do
  t=${pair%%:*}; want=${pair##*:}
  out=$(az deployment group validate -g "$RG" --template-file "$dir/$t.json" -o none 2>&1) && rc=0 || rc=$?
  if (( rc != 0 )) && grep -q "RequestDisallowedByPolicy" <<< "$out" && grep -q "$want" <<< "$out"; then
    echo "PASS: $t refused by $want"
  else
    echo "FAIL: $t not refused by $want (exit $rc): $(first_error "$out")"; fail=1
  fi
done

if out=$(az deployment group validate -g "$RG" --template-file "$dir/allowed-control.json" -o none 2>&1); then
  echo "PASS: allowed-control validates"
else
  echo "FAIL: allowed-control was refused, the test would pass for the wrong reason: $(first_error "$out")"; fail=1
fi
exit $fail
