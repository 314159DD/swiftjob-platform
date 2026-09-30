#!/usr/bin/env bash
# Access test for the environment without a VNet (spec 7): the endpoints are reachable from the internet, so
# identity must be the boundary. Run as an identity with no data role in the environment.
# The test needs no secret and no blob: every check is a refusal that holds whether or not data exists, and the
# one control proves the identity can still see the vault on the management plane.
# Output: one line per check. No response body, secret value or raw Azure message is printed on success; on
# failure expect.sh prints a redacted excerpt cut to 300 characters.
# Usage: bash scripts/access-test.sh <resource-group>
set -euo pipefail
export MSYS_NO_PATHCONV=1
# shellcheck source=/dev/null
source "$(dirname "$0")/expect.sh"
RG=${1:?resource group}
# Discovery errors are withheld (they can name subscriptions and principals); set -e fails the run closed.
KV=$(az keyvault list -g "$RG" --query "[0].name" -o tsv 2> /dev/null | tr -d '\r')
SA=$(az storage account list -g "$RG" --query "[0].name" -o tsv 2> /dev/null | tr -d '\r')
[[ -n "$KV" && -n "$SA" ]] || { echo "::error::vault or storage account not found"; exit 1; }
# A real container makes the blob checks meaningful; the names come from the environment, not from this script.
# Management plane read, so it needs no data role. A fixed probe name is the fallback when there is none yet.
CONTAINER=$(az storage container-rm list --storage-account "$SA" -g "$RG" --query "[0].name" -o tsv 2> /dev/null | tr -d '\r' || true)
CONTAINER=${CONTAINER:-access-probe}
BOGUS_KEY=$(head -c 64 /dev/zero | base64 | tr -d '\n')

# Prints the HTTP status only and succeeds only on 200, so the refusal check reads "HTTP 401" and nothing else.
anonymous_get() { # url
  local code
  code=$(curl -s -o /dev/null --max-time 30 -w '%{http_code}' "$1") || return 2
  echo "HTTP ${code}"
  [[ "$code" == 200 ]]
}
# Succeeds only when the account property is exactly the string "false" (a missing or null value fails).
account_flag_false() { # property
  local v
  v=$(az storage account show -n "$SA" -g "$RG" --query "$1" -o tsv 2> /dev/null | tr -d '') || return 2
  [[ "$v" == false ]]
}
anonymous_kv() { anonymous_get "https://${KV}.vault.azure.net/secrets?api-version=7.4"; }
anonymous_list() { anonymous_get "https://${SA}.blob.core.windows.net/${CONTAINER}?restype=container&comp=list"; }

expect_ok "control: the vault is reachable over the management plane" az keyvault show -n "$KV" -o none || true
expect_refused "read secrets without a role" "ForbiddenByRbac|Caller is not authorized to perform action"   az keyvault secret list --vault-name "$KV" -o none || true
expect_refused "list secrets anonymously" "HTTP (401|403)" anonymous_kv || true
expect_refused "read blobs without a role" "You do not have the required permissions|AuthorizationPermissionMismatch"   az storage blob list --account-name "$SA" -c "$CONTAINER" --auth-mode login -o none || true
# A bogus account key is rejected as invalid even when shared-key access is on, so the account setting is read instead.
expect_ok "account keys are switched off (allowSharedKeyAccess is false)" account_flag_false allowSharedKeyAccess || true
expect_ok "public blob access is switched off (allowBlobPublicAccess is false)" account_flag_false allowBlobPublicAccess || true
# 409 PublicAccessNotPermitted is the account-level refusal; 404 is not accepted (an open account answers it too).
expect_refused "list blobs anonymously" "HTTP (401|403|409)" anonymous_list || true
echo "INFO: PostgreSQL checks (password sign-in refused, foreign identities refused) start with plan 03"
expect_summary
