# shellcheck shell=bash
# Helper for scripts/rights-test.sh. Needs SELF (object ID) and CREATED_LOG (file) to be set.

# Tries to assign a role to the signed-in identity. Returns az's exit status, also where errexit is off (inside
# expect_refused). Every assignment that is created is recorded, so cleanup can remove it.
grant_self() { # role scope
  local id rc=0
  id=$(az role assignment create --only-show-errors --assignee-object-id "$SELF" --assignee-principal-type ServicePrincipal --role "$1" --scope "$2" --query id -o tsv) || rc=$?
  if (( rc != 0 )); then return "$rc"; fi
  id=${id//$'\r'/}
  if [[ -n "$id" ]]; then echo "$id" >> "$CREATED_LOG"; fi
}
