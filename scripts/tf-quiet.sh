#!/usr/bin/env bash
# Runs terraform for a public log. Standard output (plan and apply text) is always discarded.
#   redact:   on failure, standard error is printed through scripts/redact.sh
#   suppress: on failure, only "terraform <cmd> failed with exit code N" is printed. Used for layers whose inputs
#             are private: an error message can quote a variable value or a resource address from the private config.
#             A second line names what failed from an allowlist only: resource types (public code), Azure error codes,
#             HTTP status codes and fixed error kinds (timeout, connection, state-lock, throttled, token, inconsistent,
#             config, target). The Diagnose workflow re-plans, so an apply-time error is otherwise lost.
# TF_QUIET_OK_CODES lists exit codes that count as success (default "0"; plan -detailed-exitcode uses "0 2").
set -euo pipefail
mode=${1:-}
case "$mode" in
  redact|suppress) shift ;;
  *) echo "usage: tf-quiet.sh <redact|suppress> <terraform arguments>" >&2; exit 64 ;;
esac
sub=""
for a in "$@"; do if [[ "$a" != -* ]]; then sub=$a; break; fi; done
err=$(mktemp); trap 'rm -f "$err"' EXIT
rc=0
terraform "$@" > /dev/null 2> "$err" || rc=$?
if [[ " ${TF_QUIET_OK_CODES:-0} " != *" $rc "* ]]; then
  if [[ "$mode" == redact ]]; then
    # A failing redaction must never change the exit code, and raw stderr is never printed.
    bash "${TF_QUIET_REDACT:-$(dirname "$0")/redact.sh}" < "$err" >&2 || echo "::error::redaction failed, error output withheld" >&2
  else
    echo "::error::terraform ${sub:-command} failed with exit code ${rc}. Its error output is withheld because this layer has private inputs; run the Diagnose workflow in the configuration repository for the full text." >&2
    # Each value is cut down to a fixed character class before it is printed.
    pick() { { grep -oE "$1" "$err" || true; } | sed -E "$2" | sort -u | paste -sd ' ' -; }
    types=$(pick '(azurerm|azapi|azuread|random|time|null)_[a-z0-9_]+\.' 's/\.$//')
    # Codes: quoted Code="X", "ERROR CODE: X" (azurerm text) or one of a fixed list of well-known bare words.
    codes=$(pick '([Cc]ode[=:] ?"[A-Za-z][A-Za-z0-9]{1,60}"|ERROR CODE: ?[A-Za-z][A-Za-z0-9]{1,60}|\b(Forbidden|AuthorizationFailed|KeyVaultReferenceError|ContainerAppSecretKeyVaultUrlInvalid|RoleAssignmentExists|PrincipalNotFound|ResourceNotFound|Conflict)\b)' 's/.*[^A-Za-z0-9]([A-Za-z0-9]+)"?$/\1/')
    status=$(pick '(StatusCode[=:] ?|RESPONSE |unexpected status )[1-5][0-9]{2}' 's/.*([1-5][0-9]{2})$/\1/')
    # Kinds: fixed categories for errors that carry no Azure code (network, lock, Terraform configuration errors).
    # Only the category name is printed, never the matched text.
    kinds=$(
      while IFS='|' read -r kind pattern; do if grep -qiE "$pattern" "$err"; then echo "$kind"; fi; done <<'EOF' | sort -u | paste -sd ' ' -
timeout|context deadline exceeded|i/o timeout|Client\.Timeout|TLS handshake timeout
connection|connection reset|connection refused|broken pipe|unexpected EOF|no such host
state-lock|Error acquiring the state lock|state blob is already locked
throttled|TooManyRequests|429 Too Many Requests
token|could not acquire access token|AADSTS[0-9]+|OIDC|getting authenticated object ID
inconsistent|Provider produced inconsistent|produced an unexpected new value
config|Unsupported argument|Unsupported attribute|Invalid reference|Missing required argument|Invalid value for|Reference to undeclared|Invalid for_each argument|Invalid count argument
target|Invalid target address|Resource targeting
EOF
    )
    echo "::error::withheld error summary: types=[${types}] codes=[${codes}] status=[${status}] kinds=[${kinds}]" >&2
  fi
fi
exit "$rc"
