#!/usr/bin/env bash
# One-time bootstrap, run by a person who is Global Administrator in the tenant and Owner of the subscription.
# It creates what the pipeline deliberately cannot create for itself: the root management group, the
# Terraform state storage, the OIDC identities and their role assignments. Safe to run again.
#
#   export PATH="$PATH:/c/Program Files/Microsoft SDKs/Azure/CLI2/wbin"
#   az login && GH_TOKEN=$(gh auth token --user 314159DD) bash scripts/bootstrap.sh
set -euo pipefail
shopt -s inherit_errexit
export MSYS_NO_PATHCONV=1

GITHUB_REPO=${GITHUB_REPO:-314159DD/swiftjob-platform}
LOCATION=germanywestcentral
ROOT_MG=mg-swiftjob
STATE_RG=rg-swiftjob-tfstate
PLATFORM_RG=rg-swiftjob-platform
STAGING_RG=rg-swiftjob-staging
PROD_RG=rg-swiftjob-prod
NETTEST_RG=rg-swiftjob-nettest
CONFIG_REPO=${CONFIG_REPO:-314159DD/swiftjob-platform-config}
WORKSPACE_ID_SUFFIX=resourceGroups/rg-swiftjob-platform/providers/Microsoft.OperationalInsights/workspaces/log-swiftjob-platform
TAGS=(project=swiftjob env=platform owner=steven)
ROOT_MG_ID="/providers/Microsoft.Management/managementGroups/${ROOT_MG}"

SUB=$(az account show --query id -o tsv)
TENANT=$(az account show --query tenantId -o tsv)
ME=$(az ad signed-in-user show --query id -o tsv)

# Removes a leftover elevated root access (User Access Administrator at /). Harmless when absent.
remove_elevation() {
  if [[ "$(az role assignment list --assignee "$ME" --role "User Access Administrator" --scope / --query "[?scope=='/'] | length(@)" -o tsv)" != "0" ]]; then
    az role assignment delete --assignee "$ME" --role "User Access Administrator" --scope / -o none
  fi
}
# No exit path may leave it behind.
trap 'remove_elevation || true' EXIT

step() { printf '\n== %s\n' "$*"; }

# Creates a role assignment unless an identical one exists (az fails on duplicates).
assign() { # principal-id principal-type role scope [condition]
  local existing existing_id current
  existing=$(az role assignment list --assignee "$1" --role "$3" --scope "$4" --query "[?scope=='$4'] | length(@)" -o tsv)
  if [[ "$existing" != "0" ]]; then
    if [[ -z "${5:-}" ]]; then return 0; fi
    # Conditional assignment: keep it only if the stored condition matches (whitespace ignored).
    current=$(az role assignment list --assignee "$1" --role "$3" --scope "$4" --query "[?scope=='$4'] | [0].condition" -o tsv)
    if [[ "${current//[[:space:]]/}" == "${5//[[:space:]]/}" ]]; then return 0; fi
    existing_id=$(az role assignment list --assignee "$1" --role "$3" --scope "$4" --query "[?scope=='$4'] | [0].id" -o tsv)
    az role assignment delete --ids "$existing_id" -o none
  fi
  local args=(--assignee-object-id "$1" --assignee-principal-type "$2" --role "$3" --scope "$4" -o none)
  if [[ -n "${5:-}" ]]; then args+=(--condition "$5" --condition-version 2.0); fi
  for attempt in 1 2 3 4 5 6; do
    az role assignment create "${args[@]}" && return 0
    echo "  retry ${attempt} (new principals take a while to replicate)"; sleep 20
  done
  return 1
}

# Removes a role assignment at exactly this scope. Harmless when absent.
unassign() { # principal-id role scope
  local ids id
  ids=$(az role assignment list --assignee "$1" --role "$2" --scope "$3" --query "[?scope=='$3'].id" -o tsv | tr -d '\r')
  for id in $ids; do az role assignment delete --ids "$id" -o none; done
}

# Creates or updates a custom role definition (assignable at the scopes named inside the JSON).
# Two Azure behaviours shape this: `az role definition update` needs the existing role's id and a roleName inside the
# JSON (az 2.90 reads definition['roleName'] once an id is given). Without the id
# az reports "Role 'id' is missing", searches the current subscription only, does not find a role whose
# assignable scopes are resource groups, tries to create it and fails with RoleDefinitionWithSameNameExists). And a
# new definition is not readable at once, so after a create the lookup is polled until it returns the role.
upsert_role() { # name definition-json lookup-scope
  local existing id
  existing=$(az role definition list --name "$1" --scope "$3" --query "[0].id" -o tsv | tr -d '\r')
  if [[ -n "$existing" ]]; then
    az role definition update -o none --role-definition "$(jq --arg id "$existing" '. + {id: $id, roleName: .Name}' <<< "$2" | tr -d '\r')"
    return 0
  fi
  az role definition create -o none --role-definition "$2"
  for attempt in 1 2 3 4 5 6; do
    id=$(az role definition list --name "$1" --scope "$3" --query "[0].id" -o tsv | tr -d '\r')
    [[ -n "$id" ]] && return 0
    echo "  waiting for the role definition $1 (${attempt}/6)"; sleep 20
  done
  echo "Role definition $1 not readable after create." >&2
  return 1
}

step "Resource providers (the provider block has resource_provider_registrations = none)"
for ns in Microsoft.Management Microsoft.PolicyInsights Microsoft.Insights Microsoft.OperationalInsights \
          Microsoft.Storage Microsoft.Consumption Microsoft.CostManagement Microsoft.App Microsoft.ManagedIdentity \
          Microsoft.KeyVault Microsoft.DBforPostgreSQL Microsoft.Network Microsoft.Logic Microsoft.Web; do
  if [[ "$ns" == "Microsoft.Management" ]]; then
    az provider register --namespace "$ns" --wait -o none
  else
    az provider register --namespace "$ns" -o none
  fi
done

step "Root management group ${ROOT_MG}"
if ! az account management-group show --name "$ROOT_MG" -o none 2>/dev/null; then
  if ! az account management-group create --name "$ROOT_MG" --display-name "SwiftJob" -o none; then
    echo "Could not create the root management group. In the Azure portal open Management groups once (this initialises the hierarchy) or check 'Require write permissions for creating new management groups' under Management groups > Settings, then run this script again." >&2
    exit 1
  fi
fi
assign "$ME" User Owner "$ROOT_MG_ID"
remove_elevation

step "Resource groups"
az group create -n "$STATE_RG" -l "$LOCATION" --tags "${TAGS[@]}" -o none
az group create -n "$PLATFORM_RG" -l "$LOCATION" --tags "${TAGS[@]}" -o none
# Workload resource groups. Production stays empty until plan 05, but exists now so its policies (public network
# audit) are in place before anything lands there. nettest is the throwaway VNet test of plan 02c.
az group create -n "$STAGING_RG" -l "$LOCATION" --tags project=swiftjob env=staging owner=steven -o none
az group create -n "$PROD_RG" -l "$LOCATION" --tags project=swiftjob env=prod owner=steven -o none
az group create -n "$NETTEST_RG" -l "$LOCATION" --tags project=swiftjob env=nettest owner=steven -o none

step "Terraform state storage (Entra auth only)"
SA=$(az storage account list -g "$STATE_RG" --query "[0].name" -o tsv)
if [[ -z "$SA" ]]; then
  SA="stswiftjobtf$(openssl rand -hex 3)"
  az storage account create -n "$SA" -g "$STATE_RG" -l "$LOCATION" --sku Standard_LRS --kind StorageV2 \
    --min-tls-version TLS1_2 --allow-blob-public-access false --allow-shared-key-access false \
    --https-only true --tags "${TAGS[@]}" -o none
fi
az storage account blob-service-properties update --account-name "$SA" -g "$STATE_RG" \
  --enable-versioning true --enable-delete-retention true --delete-retention-days 30 \
  --enable-container-delete-retention true --container-delete-retention-days 30 -o none
SA_ID=$(az storage account show -n "$SA" -g "$STATE_RG" --query id -o tsv)
assign "$ME" User "Storage Blob Data Owner" "$SA_ID"
for c in platform staging prod; do
  created=0
  for attempt in $(seq 1 30); do
    if az storage container create --account-name "$SA" -n "$c" --auth-mode login -o none; then created=1; break; fi
    echo "  waiting for the data role to apply (${attempt}/30)"; sleep 20
  done
  if [[ "$created" != "1" ]]; then
    echo "Could not create storage container ${c} in ${SA}." >&2
    exit 1
  fi
done

step "GitHub OIDC identities"
subject_repo() { # owner/name -> "login@ownerId/name@repoId" (immutable IDs, as GitHub puts them in the subject)
  local json
  json=$(gh api "repos/$1")
  printf '%s@%s/%s@%s' "$(jq -r '.owner.login' <<< "$json" | tr -d '\r')" "$(jq -r '.owner.id' <<< "$json" | tr -d '\r')" \
    "$(jq -r '.name' <<< "$json" | tr -d '\r')" "$(jq -r '.id' <<< "$json" | tr -d '\r')"
}

federate() { # appId credential-name subject
  if [[ -z "$(az ad app federated-credential list --id "$1" --query "[?subject=='$3'].name" -o tsv | tr -d '\r')" ]]; then
    az ad app federated-credential create --id "$1" -o none --parameters \
      "{\"name\":\"$2\",\"issuer\":\"https://token.actions.githubusercontent.com\",\"subject\":\"$3\",\"audiences\":[\"api://AzureADTokenExchange\"]}"
  fi
}

# SUBJECT_REPO is set below, before the first call; the functions are defined first on purpose.
identity() { # display-name github-environment -> prints "appId spObjectId"
  local app sp
  app=$(az ad app list --display-name "$1" --query "[0].appId" -o tsv | tr -d '\r')
  [[ -n "$app" ]] || app=$(az ad app create --display-name "$1" --query appId -o tsv | tr -d '\r')
  sp=$(az ad sp list --filter "appId eq '$app'" --query "[0].id" -o tsv | tr -d '\r')
  if [[ -z "$sp" ]]; then
    for attempt in 1 2 3 4 5 6; do
      sp=$(az ad sp create --id "$app" --query id -o tsv | tr -d '\r') && break
      sp=""; echo "  retry ${attempt} creating the service principal" >&2; sleep 20
    done
  fi
  federate "$app" "github-$2" "repo:${SUBJECT_REPO}:environment:$2"
  echo "$app $sp"
}

SUBJECT_REPO=$(subject_repo "$GITHUB_REPO")
CONFIG_SUBJECT_REPO=$(subject_repo "$CONFIG_REPO")

read -r PLAN_APP PLAN_SP <<< "$(identity swiftjob-tf-plan plan)"
read -r PLATFORM_APP PLATFORM_SP <<< "$(identity swiftjob-tf-platform platform)"
read -r PT_APP PT_SP <<< "$(identity swiftjob-policy-test policy-test)"
read -r STAGING_APP STAGING_SP <<< "$(identity swiftjob-tf-staging staging)"
federate "$STAGING_APP" github-nettest "repo:${SUBJECT_REPO}:environment:nettest"
# The private configuration repository has no environments (GitHub Free); its Diagnose workflow uses tf-plan
# from main only.
federate "$PLAN_APP" github-config-main "repo:${CONFIG_SUBJECT_REPO}:ref:refs/heads/main"

for v in PLAN_APP PLAN_SP PLATFORM_APP PLATFORM_SP PT_APP PT_SP STAGING_APP STAGING_SP; do
  if [[ -z "${!v}" ]]; then echo "Identity creation failed: ${v} is empty." >&2; exit 1; fi
done

step "Roles: tf-plan (read everything, state included; plans are lock-free)"
assign "$PLAN_SP" ServicePrincipal Reader "$ROOT_MG_ID"
# Also Reader on the subscription: it must read the subscription before the owner moves it under the management group (Task 9).
assign "$PLAN_SP" ServicePrincipal Reader "/subscriptions/${SUB}"
# Plans run with -lock=false, so tf-plan only needs to read state. Grant the reader role first, then remove the
# old writer role, so there is no moment without read access.
for c in platform staging prod; do
  assign "$PLAN_SP" ServicePrincipal "Storage Blob Data Reader" "${SA_ID}/blobServices/default/containers/${c}"
  unassign "$PLAN_SP" "Storage Blob Data Contributor" "${SA_ID}/blobServices/default/containers/${c}"
done

step "Roles: policy-test identity (validates the forbidden templates in the platform resource group)"
PLATFORM_RG_ID="/subscriptions/${SUB}/resourceGroups/${PLATFORM_RG}"
# An earlier version gave tf-plan a validate-only role. ARM validate needs write permission per resource type in the
# template (same as what-if), so that role was not enough. Remove it again, tf-plan stays read-only (Azure resources and state).
OLD_ROLE=swiftjob-deployment-validator
if [[ -n "$(az role definition list --name "$OLD_ROLE" --scope "$PLATFORM_RG_ID" --query "[0].name" -o tsv)" ]]; then
  if [[ "$(az role assignment list --assignee "$PLAN_SP" --role "$OLD_ROLE" --scope "$PLATFORM_RG_ID" --query "length(@)" -o tsv)" != "0" ]]; then
    az role assignment delete --assignee "$PLAN_SP" --role "$OLD_ROLE" --scope "$PLATFORM_RG_ID" -o none
  fi
  if [[ "$(az role assignment list --all --query "[?roleDefinitionName=='$OLD_ROLE'] | length(@)" -o tsv)" == "0" ]]; then
    az role definition delete --name "$OLD_ROLE" --scope "$PLATFORM_RG_ID" -o none       || echo "warn: could not delete role definition $OLD_ROLE yet, next run will retry" >&2
  fi
fi
# Validate needs write permission for every resource type in the template, like what-if. The deny policies still
# refuse the forbidden templates, and this identity can only be used from main (environment policy-test).
TESTER_ROLE=swiftjob-policy-tester
TESTER_DEF=$(jq -n --arg name "$TESTER_ROLE" --arg scope "$PLATFORM_RG_ID" '{
  Name: $name,
  Description: "Validate the policy test templates in the platform resource group (validate needs write per resource type).",
  Actions: ["Microsoft.Resources/deployments/validate/action", "Microsoft.Resources/deployments/read",
            "Microsoft.Storage/storageAccounts/write", "Microsoft.Network/natGateways/write",
            "Microsoft.DBforPostgreSQL/flexibleServers/write", "Microsoft.Resources/subscriptions/resourceGroups/read",
            "Microsoft.Web/staticSites/write", "Microsoft.App/managedEnvironments/write", "Microsoft.Network/loadBalancers/write",
            "Microsoft.Network/privateEndpoints/write", "Microsoft.Network/virtualNetworks/subnets/join/action"],
  AssignableScopes: [$scope]}')
upsert_role "$TESTER_ROLE" "$TESTER_DEF" "$PLATFORM_RG_ID"
assign "$PT_SP" ServicePrincipal "$TESTER_ROLE" "$PLATFORM_RG_ID"

step "Roles: tf-platform (management groups, policy, the platform resource group, the budget)"
assign "$PLATFORM_SP" ServicePrincipal Reader "$ROOT_MG_ID"
assign "$PLATFORM_SP" ServicePrincipal "Management Group Contributor" "$ROOT_MG_ID"
assign "$PLATFORM_SP" ServicePrincipal "Resource Policy Contributor" "$ROOT_MG_ID"
assign "$PLATFORM_SP" ServicePrincipal Contributor "/subscriptions/${SUB}/resourceGroups/${PLATFORM_RG}"
assign "$PLATFORM_SP" ServicePrincipal "Cost Management Contributor" "/subscriptions/${SUB}"
assign "$PLATFORM_SP" ServicePrincipal "Storage Blob Data Contributor" "${SA_ID}/blobServices/default/containers/platform"
# It may grant exactly two roles, to the managed identities of DeployIfNotExists policy assignments:
# Log Analytics Contributor and Monitoring Contributor. Owner and everything else is refused.
ALLOWED='92aaf0da-9dab-42b6-94a3-d43ce8d16293, 749f88d5-cbae-40b8-bcfc-e573ddc772fa'
CONDITION="((!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})) OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {${ALLOWED}})) AND ((!(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})) OR (@Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {${ALLOWED}}))"
assign "$PLATFORM_SP" ServicePrincipal "Role Based Access Control Administrator" "$ROOT_MG_ID" "$CONDITION"

step "Custom roles for the workload layers"
SUB_ID="/subscriptions/${SUB}"
STAGING_RG_ID="${SUB_ID}/resourceGroups/${STAGING_RG}"
PROD_RG_ID="${SUB_ID}/resourceGroups/${PROD_RG}"
NETTEST_RG_ID="${SUB_ID}/resourceGroups/${NETTEST_RG}"
WORKLOAD_SCOPES=$(jq -nc --arg a "$STAGING_RG_ID" --arg b "$PROD_RG_ID" --arg c "$NETTEST_RG_ID" '[$a, $b, $c]' | tr -d '\r')

# The kill switch Logic App may stop and start the container apps of its own environment and nothing else.
upsert_role swiftjob-containerapp-stopper "$(jq -n --argjson scopes "$WORKLOAD_SCOPES" '{
  Name: "swiftjob-containerapp-stopper",
  Description: "Read, stop and start container apps (kill switch).",
  Actions: ["Microsoft.App/containerApps/read", "Microsoft.App/containerApps/stop/action", "Microsoft.App/containerApps/start/action"],
  AssignableScopes: $scopes}' | tr -d '\r')" "$STAGING_RG_ID"
# A new role definition takes a while to be readable. An empty ID would leave ", }" in the ABAC condition below.
STOPPER_ID=""
for attempt in 1 2 3 4 5 6; do
  STOPPER_ID=$(az role definition list --name swiftjob-containerapp-stopper --scope "$STAGING_RG_ID" --query "[0].name" -o tsv | tr -d '\r')
  [[ -n "$STOPPER_ID" ]] && break
  echo "  waiting for the role definition swiftjob-containerapp-stopper (${attempt}/6)"; sleep 20
done
if [[ -z "$STOPPER_ID" ]]; then echo "Role definition swiftjob-containerapp-stopper not readable." >&2; exit 1; fi

# terraform plan refreshes every resource. For these types the provider calls an action that Reader does not
# include: container app and job secrets (Key Vault references only, no values) and the kill switch trigger URL.
upsert_role swiftjob-plan-reader "$(jq -n --argjson scopes "$WORKLOAD_SCOPES" '{
  Name: "swiftjob-plan-reader",
  Description: "Refresh-only actions that Reader lacks, for terraform plan of the workload layers.",
  Actions: ["Microsoft.App/containerApps/listSecrets/action", "Microsoft.App/jobs/listSecrets/action",
            "Microsoft.Logic/workflows/triggers/listCallbackUrl/action"],
  AssignableScopes: $scopes}' | tr -d '\r')" "$STAGING_RG_ID"
assign "$PLAN_SP" ServicePrincipal swiftjob-plan-reader "$STAGING_RG_ID"
assign "$PLAN_SP" ServicePrincipal swiftjob-plan-reader "$PROD_RG_ID"

step "Roles: tf-staging (the staging and nettest resource groups, its own state container)"
assign "$STAGING_SP" ServicePrincipal Contributor "$STAGING_RG_ID"
assign "$STAGING_SP" ServicePrincipal Contributor "$NETTEST_RG_ID"
assign "$STAGING_SP" ServicePrincipal "Storage Blob Data Contributor" "${SA_ID}/blobServices/default/containers/staging"
# Log Analytics Contributor on the central workspace also lets it change the daily cap, retention or delete the
# workspace. Accepted for phase 2 (the nightly platform drift shows a changed cap); a narrower custom role is a
# plan 05 item.
assign "$STAGING_SP" ServicePrincipal "Log Analytics Contributor" "${SUB_ID}/${WORKSPACE_ID_SUFFIX}"
# It may grant exactly the app data roles, only to service principals (managed identities, Logic App identities)
# other than itself: Key Vault Secrets User, Storage Blob Data Contributor, Storage Blob Data Reader, Monitoring
# Metrics Publisher, and the kill switch role. Excluding its own principal ID blocks the direct self-grant of Key
# Vault Secrets User. The residual path (Contributor on the staging RG can deploy a workload whose identity holds
# that role) is recorded in ADR 0005.
ALLOWED_APP="4633458b-17de-408a-b874-0445c86b69e6, ba92f5b4-2d11-453d-a403-e96b0029c9fe, 2a2b9908-6ea1-4ae2-8e65-a410df84e7d1, 3913510d-42f4-4e42-8a64-420c390055eb, ${STOPPER_ID}"
APP_CONDITION="((!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})) OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {${ALLOWED_APP}} AND @Request[Microsoft.Authorization/roleAssignments:PrincipalType] StringEqualsIgnoreCase 'ServicePrincipal' AND @Request[Microsoft.Authorization/roleAssignments:PrincipalId] ForAnyOfAllValues:GuidNotEquals {${STAGING_SP}})) AND ((!(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})) OR (@Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {${ALLOWED_APP}} AND @Resource[Microsoft.Authorization/roleAssignments:PrincipalType] StringEqualsIgnoreCase 'ServicePrincipal'))"
assign "$STAGING_SP" ServicePrincipal "Role Based Access Control Administrator" "$STAGING_RG_ID" "$APP_CONDITION"
assign "$STAGING_SP" ServicePrincipal "Role Based Access Control Administrator" "$NETTEST_RG_ID" "$APP_CONDITION"

step "Pipeline identities hold no Owner or User Access Administrator anywhere under ${ROOT_MG}"
# Azure makes the creator of a management group its Owner. Terraform (tf-platform) creates management groups,
# so Azure assigns it Owner on each new one. Nothing in Terraform tracks those assignments, so drift cannot see
# them. Remove them here. `az role assignment list --all` does not list management group scopes, so every
# management group under the root is listed explicitly. The nightly Drift workflow runs scripts/rbac-guard.sh.
MG_NAMES=$(az account management-group show --name "$ROOT_MG" --expand --recurse -o json \
  | jq -r '.. | objects | select(.type? == "Microsoft.Management/managementGroups") | .name' | tr -d '\r' | sort -u)
if ! grep -qx "$ROOT_MG" <<< "$MG_NAMES"; then echo "Management group enumeration did not include ${ROOT_MG}." >&2; exit 1; fi
for sp in "$PLAN_SP" "$PLATFORM_SP" "$PT_SP" "$STAGING_SP"; do
  ids=$(az role assignment list --all --assignee "$sp" --query "[?roleDefinitionName=='Owner' || roleDefinitionName=='User Access Administrator'].id" -o tsv)
  for mg in $MG_NAMES; do
    mg_ids=$(az role assignment list --assignee "$sp" --scope "/providers/Microsoft.Management/managementGroups/${mg}" \
      --query "[?roleDefinitionName=='Owner' || roleDefinitionName=='User Access Administrator'].id" -o tsv)
    ids=$(printf '%s\n%s\n' "$ids" "$mg_ids" | tr -d '\r' | sed '/^$/d' | sort -u)
  done
  for id in $ids; do
    echo "  removing ${id}"
    az role assignment delete --ids "$id" -o none
  done
done

step "Done. Values for scripts/configure-github.sh:"
cat <<EOF
AZURE_TENANT_ID=${TENANT}
AZURE_SUBSCRIPTION_ID=${SUB}
TF_STATE_RG=${STATE_RG}
TF_STATE_SA=${SA}
AZURE_CLIENT_ID_PLAN=${PLAN_APP}
AZURE_CLIENT_ID_PLATFORM=${PLATFORM_APP}
AZURE_CLIENT_ID_POLICY_TEST=${PT_APP}
AZURE_CLIENT_ID_STAGING=${STAGING_APP}
PIPELINE_PRINCIPAL_IDS=${PLAN_SP} ${PLATFORM_SP} ${PT_SP} ${STAGING_SP}
EOF
