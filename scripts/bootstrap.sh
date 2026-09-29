#!/usr/bin/env bash
# One-time bootstrap, run by a person who is Global Administrator in the tenant and Owner of the subscription.
# It creates what the pipeline deliberately cannot create for itself: the root management group, the
# Terraform state storage, the OIDC identities and their role assignments. Safe to run again.
#
#   export PATH="$PATH:/c/Program Files/Microsoft SDKs/Azure/CLI2/wbin"
#   az login && GH_TOKEN=$(gh auth token --user 314159DD) bash scripts/bootstrap.sh
set -euo pipefail
export MSYS_NO_PATHCONV=1

GITHUB_REPO=${GITHUB_REPO:-314159DD/swiftjob-platform}
LOCATION=germanywestcentral
ROOT_MG=mg-swiftjob
STATE_RG=rg-swiftjob-tfstate
PLATFORM_RG=rg-swiftjob-platform
TAGS=(project=swiftjob env=platform owner=steven)
ROOT_MG_ID="/providers/Microsoft.Management/managementGroups/${ROOT_MG}"

SUB=$(az account show --query id -o tsv)
TENANT=$(az account show --query tenantId -o tsv)
ME=$(az ad signed-in-user show --query id -o tsv)

step() { printf '\n== %s\n' "$*"; }

# Creates a role assignment unless an identical one exists (az fails on duplicates).
assign() { # principal-id principal-type role scope [condition]
  local existing
  existing=$(az role assignment list --assignee "$1" --role "$3" --scope "$4" --query "[?scope=='$4'] | length(@)" -o tsv)
  if [[ "$existing" != "0" ]]; then return 0; fi
  local args=(--assignee-object-id "$1" --assignee-principal-type "$2" --role "$3" --scope "$4" -o none)
  if [[ -n "${5:-}" ]]; then args+=(--condition "$5" --condition-version 2.0); fi
  for attempt in 1 2 3 4 5 6; do
    az role assignment create "${args[@]}" && return 0
    echo "  retry ${attempt} (new principals take a while to replicate)"; sleep 20
  done
  return 1
}

step "Resource providers (the provider block has resource_provider_registrations = none)"
for ns in Microsoft.Management Microsoft.PolicyInsights Microsoft.Insights Microsoft.OperationalInsights \
          Microsoft.Storage Microsoft.Consumption Microsoft.CostManagement Microsoft.App Microsoft.ManagedIdentity \
          Microsoft.KeyVault Microsoft.DBforPostgreSQL Microsoft.Network; do
  az provider register --namespace "$ns" -o none
done

step "Root management group ${ROOT_MG}"
if ! az account management-group show --name "$ROOT_MG" -o none 2>/dev/null; then
  if ! az account management-group create --name "$ROOT_MG" --display-name "SwiftJob" -o none; then
    # Some tenants require write access at root to create the first management group. A Global
    # Administrator gets it only by elevating, and the elevation is removed again right after.
    az rest --method post --url "https://management.azure.com/providers/Microsoft.Authorization/elevateAccess?api-version=2016-07-01"
    sleep 60
    az account management-group create --name "$ROOT_MG" --display-name "SwiftJob" -o none
  fi
fi
assign "$ME" User Owner "$ROOT_MG_ID"
# Never leave the elevated root access behind.
if [[ "$(az role assignment list --assignee "$ME" --role "User Access Administrator" --scope / --query "[?scope=='/'] | length(@)" -o tsv)" != "0" ]]; then
  az role assignment delete --assignee "$ME" --role "User Access Administrator" --scope / -o none
fi

step "Resource groups"
az group create -n "$STATE_RG" -l "$LOCATION" --tags "${TAGS[@]}" -o none
az group create -n "$PLATFORM_RG" -l "$LOCATION" --tags "${TAGS[@]}" -o none

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
  for attempt in 1 2 3 4 5 6; do
    az storage container create --account-name "$SA" -n "$c" --auth-mode login -o none && break
    echo "  waiting for the data role to apply"; sleep 20
  done
done

step "GitHub OIDC identities"
REPO_JSON=$(gh api "repos/${GITHUB_REPO}")
SUBJECT_REPO="$(jq -r '.owner.login' <<< "$REPO_JSON")@$(jq -r '.owner.id' <<< "$REPO_JSON")/$(jq -r '.name' <<< "$REPO_JSON")@$(jq -r '.id' <<< "$REPO_JSON")"

identity() { # display-name github-environment -> prints "appId spObjectId"
  local app sp subject
  app=$(az ad app list --display-name "$1" --query "[0].appId" -o tsv)
  [[ -n "$app" ]] || app=$(az ad app create --display-name "$1" --query appId -o tsv)
  sp=$(az ad sp list --filter "appId eq '$app'" --query "[0].id" -o tsv)
  [[ -n "$sp" ]] || sp=$(az ad sp create --id "$app" --query id -o tsv)
  subject="repo:${SUBJECT_REPO}:environment:$2"
  if [[ -z "$(az ad app federated-credential list --id "$app" --query "[?subject=='$subject'].name" -o tsv)" ]]; then
    az ad app federated-credential create --id "$app" -o none --parameters \
      "{\"name\":\"github-$2\",\"issuer\":\"https://token.actions.githubusercontent.com\",\"subject\":\"$subject\",\"audiences\":[\"api://AzureADTokenExchange\"]}"
  fi
  echo "$app $sp"
}

read -r PLAN_APP PLAN_SP <<< "$(identity swiftjob-tf-plan plan)"
read -r PLATFORM_APP PLATFORM_SP <<< "$(identity swiftjob-tf-platform platform)"

step "Roles: tf-plan (read everything, write only the state lock)"
assign "$PLAN_SP" ServicePrincipal Reader "$ROOT_MG_ID"
for c in platform staging prod; do
  assign "$PLAN_SP" ServicePrincipal "Storage Blob Data Contributor" "${SA_ID}/blobServices/default/containers/${c}"
done

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

step "Done. Values for scripts/configure-github.sh:"
cat <<EOF
AZURE_TENANT_ID=${TENANT}
AZURE_SUBSCRIPTION_ID=${SUB}
TF_STATE_RG=${STATE_RG}
TF_STATE_SA=${SA}
AZURE_CLIENT_ID_PLAN=${PLAN_APP}
AZURE_CLIENT_ID_PLATFORM=${PLATFORM_APP}
EOF
