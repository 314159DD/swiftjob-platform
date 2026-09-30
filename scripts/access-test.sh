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
  v=$(az storage account show -n "$SA" -g "$RG" --query "$1" -o tsv 2> /dev/null | tr -d '\r') || return 2
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

# PostgreSQL: Entra ID sign-in only, TLS required. The sign-in checks need a route to the server, so the test
# opens a firewall rule for this runner's address and removes it on exit, also on failure.
# Discovery errors are withheld and fail the run closed; only an empty, successful list means "no server".
fail_check() { echo "FAIL: $1"; EXPECT_FAILURES=$((EXPECT_FAILURES + 1)); }
pg_list=$(az postgres flexible-server list -g "$RG" --query "[0].name" -o tsv 2> /dev/null) || pg_list="?"
PG=$(tr -d '\r' <<< "$pg_list")
pg_value() { # jmespath; fails when the call fails
  local v
  v=$(az postgres flexible-server show -n "$PG" -g "$RG" --query "$1" -o tsv 2> /dev/null) || return 2
  tr -d '\r' <<< "$v"
}
pg_is() { # jmespath expected
  local v
  v=$(pg_value "$1") || return 2
  [[ "$v" == "$2" ]]
}
pg_param_is() { # parameter expected
  local v
  v=$(az postgres flexible-server parameter show -s "$PG" -g "$RG" -n "$1" --query value -o tsv 2> /dev/null) || return 2
  v=$(tr -d '\r' <<< "$v")
  [[ "${v,,}" == "${2,,}" ]]
}
# One sign-in attempt; prints psql's own message, which expect_refused matches and redacts.
pg_signin() { # sslmode password user
  PGPASSWORD="$2" PGCONNECT_TIMEOUT=15 psql "host=${PG_HOST} port=5432 dbname=postgres user=$3 sslmode=$1" -w -At -c 'select 1' < /dev/null
}
pg_password() { pg_signin require wrong-password-probe access-probe; }
# The runner signs in under its own principal name with its own valid token, so user and token match and the
# refusal can only come from the missing role mapping (not from a user name mismatch).
pg_foreign() {
  local t u
  t=$(az account get-access-token --resource-type oss-rdbms --query accessToken -o tsv 2> /dev/null) || return 2
  u=$(az account show --query user.name -o tsv 2> /dev/null) || return 2
  t=$(tr -d '\r' <<< "$t"); u=$(tr -d '\r' <<< "$u")
  [[ -n "$t" && -n "$u" ]] || return 2
  pg_signin require "$t" "$u"
}
pg_plain() { pg_signin disable wrong-password-probe access-probe; }
pg_close_rule() { az postgres flexible-server firewall-rule delete -g "$RG" -s "$PG" --name access-test-probe --yes -o none 2> /dev/null || true; }

if [[ "$pg_list" == "?" ]]; then
  fail_check "PostgreSQL server discovery failed, database checks not run"
elif [[ -z "$PG" ]]; then
  if [[ "${REQUIRE_POSTGRES:-0}" == 1 ]]; then fail_check "no PostgreSQL server found"
  else echo "INFO: no PostgreSQL server in this environment, database checks skipped"; fi
else
  expect_ok "password sign-in is switched off (authConfig.passwordAuth is Disabled)" pg_is authConfig.passwordAuth Disabled || true
  expect_ok "Entra sign-in is switched on (authConfig.activeDirectoryAuth is Enabled)" pg_is authConfig.activeDirectoryAuth Enabled || true
  expect_ok "TLS is required (require_secure_transport is on)" pg_param_is require_secure_transport on || true
  PG_STATE=$(pg_value state) || PG_STATE=""
  PG_HOST=$(pg_value fullyQualifiedDomainName) || PG_HOST=""
  if [[ -z "$PG_STATE" || -z "$PG_HOST" ]]; then
    fail_check "database state or address unknown, sign-in checks not run"
  elif [[ "$PG_STATE" != Ready ]]; then
    echo "INFO: database stopped, sign-in checks skipped"
  else
    RUNNER_IP=$(curl -s --max-time 15 https://api.ipify.org || true)
    if [[ ! "$RUNNER_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
      fail_check "runner address unknown, sign-in checks not run"
    else
      trap pg_close_rule EXIT
      # set -e would end the script here without a FAIL line, so the create is checked explicitly.
      if ! az postgres flexible-server firewall-rule create -g "$RG" -s "$PG" --name access-test-probe         --start-ip-address "$RUNNER_IP" --end-ip-address "$RUNNER_IP" -o none 2> /dev/null; then
        fail_check "probe firewall rule not created, sign-in checks not run"
      else
        expect_refused "sign-in with a password" "password authentication failed" pg_password || true
        expect_refused "sign-in with a foreign Entra identity" "password authentication failed|role \"[^\"]+\" does not exist|not authorized" pg_foreign || true
        expect_refused "sign-in without TLS" "no pg_hba.conf entry.*no encryption|SSL connection is required" pg_plain || true
      fi
    fi
  fi
fi
expect_summary
