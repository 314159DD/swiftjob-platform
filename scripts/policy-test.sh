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
for pair in storage-shared-key:deny-storage-shared-key wrong-region:allowed-locations-v2 \
           storage-eastus2:allowed-locations-v2 storage-swedencentral:allowed-locations-v2 postgres-francecentral:allowed-locations-v2 nat-gateway:deny-costly-types postgres-large:deny-costly-skus \
           postgres-password-auth:deny-pg-password-auth containerapps-dedicated:deny-network-cost \
           containerapps-vnet:deny-network-cost \
           loadbalancer-standard:deny-network-cost private-endpoint:deny-network-cost; do
  t=${pair%%:*}; want=${pair##*:}
  out=$(az deployment group validate -g "$RG" --template-file "$dir/$t.json" -o none 2>&1) && rc=0 || rc=$?
  if (( rc != 0 )) && grep -q "RequestDisallowedByPolicy" <<< "$out" && grep -q "$want" <<< "$out"; then
    echo "PASS: $t refused by $want"
  else
    echo "FAIL: $t not refused by $want (exit $rc): $(first_error "$out")"; fail=1
  fi
done

# Azure evaluates policy before the resource provider's preflight. A trial subscription allows one Container Apps
# environment, and staging holds it, so the provider refuses the control with a quota error. That error without
# RequestDisallowedByPolicy still proves the policy let the environment through. Only these two codes count.
quota='MaxNumberOf(Regional|Global)EnvironmentsInSubExceeded'
for control in allowed-control static-site-eastus2 containerapps-env-swedencentral postgres-swedencentral; do
  if out=$(az deployment group validate -g "$RG" --template-file "$dir/$control.json" -o none 2>&1); then
    echo "PASS: $control validates"
  elif [[ "$control" == containerapps-env-* ]] && ! grep -q "RequestDisallowedByPolicy" <<< "$out" && grep -qE "$quota" <<< "$out"; then
    echo "PASS: $control passes policy (provider quota refused it after the policy check)"
  else
    echo "FAIL: $control was refused, the test would pass for the wrong reason: $(first_error "$out")"; fail=1
  fi
done
exit $fail
