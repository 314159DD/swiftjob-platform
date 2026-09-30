# shellcheck shell=bash
# Helper for scripts/rights-test.sh. Needs SELF (object ID) and CREATED_LOG (file) to be set.

# Tries to assign a role to a service principal. Returns az's exit status, also where errexit is off (inside
# expect_refused). Every assignment that is created is recorded, so cleanup can remove it.
grant_to() { # principal-object-id role scope
  local id rc=0
  id=$(az role assignment create --only-show-errors --assignee-object-id "$1" --assignee-principal-type ServicePrincipal --role "$2" --scope "$3" --query id -o tsv) || rc=$?
  if (( rc != 0 )); then return "$rc"; fi
  id=${id//$'\r'/}
  if [[ -n "$id" ]]; then echo "$id" >> "$CREATED_LOG"; fi
}

# The same for the signed-in identity.
grant_self() { # role scope
  grant_to "$SELF" "$1" "$2"
}
