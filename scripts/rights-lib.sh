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

# The control grants an allowed role to a service principal other than the identity under test (the ABAC condition
# excludes the identity's own principal ID, so even an allowed role is refused as a self-grant), then removes it by
# the ID that was just recorded. Fails when the grant or the removal fails. Needs STAGING_RG_ID and, optionally,
# PIPELINE_PRINCIPAL_IDS.
grant_and_remove_allowed() {
  local other="" id assignment
  for id in ${PIPELINE_PRINCIPAL_IDS:-}; do
    id=${id//$'\r'/}
    if [[ "${id,,}" != "${SELF,,}" ]]; then other=$id; break; fi
  done
  if [[ -z "$other" ]]; then echo "no other pipeline principal ID for the control (PIPELINE_PRINCIPAL_IDS)" >&2; return 1; fi
  grant_to "$other" "Monitoring Metrics Publisher" "$STAGING_RG_ID" || return 1
  assignment=$(tail -n 1 "$CREATED_LOG")
  if [[ -z "$assignment" ]]; then echo "the grant returned no assignment ID" >&2; return 1; fi
  az role assignment delete --only-show-errors --ids "$assignment" -o none
}
