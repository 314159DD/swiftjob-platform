#!/usr/bin/env bash
# Runs the smoke test against the staging apps, failing closed. Usage: bash scripts/smoke-staging.sh   (needs a signed-in az)
# It skips only on a positive answer: an app that does not exist (ResourceNotFound), or an app that runs an image
# outside ghcr.io/ (a placeholder). Any other az failure, an empty answer or a missing extension fails the step.
# Nothing az prints is shown, only fixed messages.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
rg=${SMOKE_RG:-rg-swiftjob-staging}; prefix=${SMOKE_APP_PREFIX:-ca-swiftjob-staging}
smoke=${SMOKE_TEST:-$root/scripts/smoke-test.sh}
die() { echo "::error::smoke test: $1"; exit 1; }

if ! az extension show --name containerapp > /dev/null 2>&1; then
  az extension add --name containerapp --yes --only-show-errors > /dev/null 2>&1 || die "could not install the containerapp az extension"
fi

err=$(mktemp); trap 'rm -f "$err"' EXIT
declare -A fqdn image
missing=0
for app in web api; do
  rc=0
  out=$(az containerapp show -g "$rg" -n "${prefix}-${app}" \
    --query "[properties.configuration.ingress.fqdn, properties.template.containers[0].image]" -o tsv 2> "$err") || rc=$?
  if (( rc != 0 )); then
    # Only the app itself missing counts; a wrong resource group or subscription has other codes and fails.
    if grep -qE "\(ResourceNotFound\).*containerApps/${prefix}-${app}'" "$err"; then missing=1; continue; fi
    die "could not read the ${app} app"
  fi
  out=$(tr -d '\r' <<< "$out")
  fqdn[$app]=$(sed -n 1p <<< "$out"); image[$app]=$(sed -n 2p <<< "$out")
  [[ -n "${fqdn[$app]}" && "${fqdn[$app]}" != None && -n "${image[$app]}" && "${image[$app]}" != None ]] || die "the ${app} app returned no address or image"
done
if (( missing )); then echo "No apps deployed yet, smoke test skipped"; exit 0; fi
if [[ "${image[web]}" != ghcr.io/* || "${image[api]}" != ghcr.io/* ]]; then
  echo "Apps do not run product images yet, smoke test skipped"; exit 0
fi
bash "$smoke" "https://${fqdn[web]}" "https://${fqdn[api]}"
