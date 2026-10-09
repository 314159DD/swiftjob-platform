#!/usr/bin/env bash
# Proves what a pipeline identity may NOT do (spec section 7, "Rechte-Test"), with one control per identity that
# must still work, so the test cannot pass because everything is refused.
# Usage (signed in as the identity under test): bash scripts/rights-test.sh <plan|staging|prod>
# Env: TF_STATE_SA; for staging also PIPELINE_PRINCIPAL_IDS (space-separated object IDs of the pipeline identities;
# one that is not the identity under test is the target of the allowed-grant control) and RIGHTS_TEST_USER_ID (object
# ID of a user, target of the refused grant to a user; the test fails when it is empty).
set -euo pipefail
export MSYS_NO_PATHCONV=1
# shellcheck source=/dev/null
source "$(dirname "$0")/expect.sh"
who=${1:?plan or staging}
SA=${TF_STATE_SA:?}
SUB=$(az account show --query id -o tsv | tr -d '\r')
SELF=$(az account get-access-token --query accessToken -o tsv | tr -d '\r' | python3 -c '
import base64, json, sys
p = sys.stdin.read().split(".")[1]; p += "=" * (-len(p) % 4)
print(json.loads(base64.urlsafe_b64decode(p))["oid"])')
STAGING_RG_ID="/subscriptions/${SUB}/resourceGroups/rg-swiftjob-staging"
PROD_RG_ID="/subscriptions/${SUB}/resourceGroups/rg-swiftjob-prod"
# Role definition ID of Monitoring Reader: the ID form makes the write itself the thing under test.
MONITORING_READER=43d0d8ad-25c7-4714-9337-8ba259a9fe05
CREATED_LOG=$(mktemp)
# shellcheck source=/dev/null
source "$(dirname "$0")/rights-lib.sh"
# Best effort: a failing refusal check must not leave real changes behind. Errors here never change the exit code
# and nothing raw is printed.
cleanup() {
  local id
  set +e
  # A refusal check that was unexpectedly allowed must not leave its tag behind (only staging can reach these).
  if [[ "${who:-}" == staging || "${who:-}" == prod ]]; then
    if [[ "${who:-}" == staging ]]; then az group update --only-show-errors -n rg-swiftjob-prod --remove tags.rightstest -o none > /dev/null 2>&1; fi
    if [[ "${who:-}" == prod ]]; then az group update --only-show-errors -n rg-swiftjob-staging --remove tags.rightstest -o none > /dev/null 2>&1; fi
    az group update --only-show-errors -n rg-swiftjob-platform --remove tags.rightstest -o none > /dev/null 2>&1
  fi
  local c
  for c in platform staging prod; do
    az storage blob delete --only-show-errors --account-name "$SA" -c "$c" -n rights-test.txt --auth-mode login -o none > /dev/null 2>&1
  done
  if [[ "$(az group exists --only-show-errors -n rg-swiftjob-rights-test 2> /dev/null | tr -d '\r')" == "true" ]]; then
    az group delete --only-show-errors -n rg-swiftjob-rights-test --yes --no-wait > /dev/null 2>&1
  fi
  while read -r id; do
    [[ -n "$id" ]] && az role assignment delete --only-show-errors --ids "$id" -o none > /dev/null 2>&1
  done < "$CREATED_LOG"
  rm -f "$CREATED_LOG"
  return 0
}
trap cleanup EXIT
case "$who" in
  plan)
    expect_refused "create a resource group" "AuthorizationFailed" \
      az group create --only-show-errors -n rg-swiftjob-rights-test -l germanywestcentral --tags project=swiftjob env=test owner=steven -o none || true
    expect_refused "write to the platform state container" "AuthorizationPermissionMismatch|AuthorizationFailure|You do not have the required permissions" \
      az storage blob upload --only-show-errors --account-name "$SA" -c platform -n rights-test.txt --data x --overwrite --auth-mode login -o none || true
    expect_refused "grant itself a role on the subscription" "AuthorizationFailed" \
      grant_self "$MONITORING_READER" "/subscriptions/${SUB}" || true
    expect_refused "write to the staging state container" "AuthorizationPermissionMismatch|AuthorizationFailure|You do not have the required permissions"       az storage blob upload --only-show-errors --account-name "$SA" -c staging -n rights-test.txt --data x --overwrite --auth-mode login -o none || true
    expect_refused "write to the prod state container" "AuthorizationPermissionMismatch|AuthorizationFailure|You do not have the required permissions"       az storage blob upload --only-show-errors --account-name "$SA" -c prod -n rights-test.txt --data x --overwrite --auth-mode login -o none || true
    expect_ok "read the platform state container" \
      az storage blob list --only-show-errors --account-name "$SA" -c platform --auth-mode login --num-results 1 -o none || true
    ;;
  staging)
    expect_refused "change the production resource group" "AuthorizationFailed" \
      az group update --only-show-errors -n rg-swiftjob-prod --set tags.rightstest=1 -o none || true
    expect_refused "change the platform resource group" "AuthorizationFailed" \
      az group update --only-show-errors -n rg-swiftjob-platform --set tags.rightstest=1 -o none || true
    expect_refused "grant itself a role not on the ABAC list on staging" "AuthorizationFailed|does not have authorization" \
      grant_self "Monitoring Reader" "$STAGING_RG_ID" || true
    expect_refused "grant itself Key Vault Secrets User on the staging RG" "AuthorizationFailed|does not have authorization" \
      grant_self "Key Vault Secrets User" "$STAGING_RG_ID" || true
    expect_refused "grant itself a role on the subscription" "AuthorizationFailed|does not have authorization" \
      grant_self "$MONITORING_READER" "/subscriptions/${SUB}" || true
    expect_refused "write to the platform state container" "AuthorizationPermissionMismatch|AuthorizationFailure|You do not have the required permissions" \
      az storage blob upload --only-show-errors --account-name "$SA" -c platform -n rights-test.txt --data x --overwrite --auth-mode login -o none || true
    expect_refused "write to the prod state container" "AuthorizationPermissionMismatch|AuthorizationFailure|You do not have the required permissions"       az storage blob upload --only-show-errors --account-name "$SA" -c prod -n rights-test.txt --data x --overwrite --auth-mode login -o none || true
    expect_refused "grant an allowed role to a user on the staging RG" "AuthorizationFailed|does not have authorization"       grant_to_user "Monitoring Metrics Publisher" "$STAGING_RG_ID" || true
    expect_ok "grant and remove an allowed role for another service principal" grant_and_remove_allowed || true
    ;;
  prod)
    # tf-prod: the mirror image of tf-staging. It must not touch staging or platform, and its ABAC list is the same.
    export RIGHTS_CONTROL_RG_ID="$PROD_RG_ID"
    expect_refused "change the staging resource group" "AuthorizationFailed" \
      az group update --only-show-errors -n rg-swiftjob-staging --set tags.rightstest=1 -o none || true
    expect_refused "change the platform resource group" "AuthorizationFailed" \
      az group update --only-show-errors -n rg-swiftjob-platform --set tags.rightstest=1 -o none || true
    expect_refused "grant itself a role not on the ABAC list on production" "AuthorizationFailed|does not have authorization" \
      grant_self "Monitoring Reader" "$PROD_RG_ID" || true
    expect_refused "grant itself Key Vault Secrets User on the production RG" "AuthorizationFailed|does not have authorization" \
      grant_self "Key Vault Secrets User" "$PROD_RG_ID" || true
    expect_refused "grant itself a role on the subscription" "AuthorizationFailed|does not have authorization" \
      grant_self "$MONITORING_READER" "/subscriptions/${SUB}" || true
    expect_refused "write to the platform state container" "AuthorizationPermissionMismatch|AuthorizationFailure|You do not have the required permissions" \
      az storage blob upload --only-show-errors --account-name "$SA" -c platform -n rights-test.txt --data x --overwrite --auth-mode login -o none || true
    expect_refused "write to the staging state container" "AuthorizationPermissionMismatch|AuthorizationFailure|You do not have the required permissions" \
      az storage blob upload --only-show-errors --account-name "$SA" -c staging -n rights-test.txt --data x --overwrite --auth-mode login -o none || true
    expect_refused "grant an allowed role to a user on the production RG" "AuthorizationFailed|does not have authorization" \
      grant_to_user "Monitoring Metrics Publisher" "$PROD_RG_ID" || true
    expect_ok "grant and remove an allowed role for another service principal" grant_and_remove_allowed || true
    ;;
  *) echo "usage: rights-test.sh <plan|staging|prod>" >&2; exit 2 ;;
esac
expect_summary
