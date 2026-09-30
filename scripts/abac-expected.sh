# shellcheck shell=bash
# Role definition GUIDs that the conditioned Role Based Access Control Administrator assignments may grant. Single
# source: scripts/bootstrap.sh builds the conditions from these lists and scripts/rbac-guard.sh checks the live
# conditions against them. Source this file.

# tf-platform: Log Analytics Contributor, Monitoring Contributor (DeployIfNotExists policy identities).
ABAC_PLATFORM_ROLES=(92aaf0da-9dab-42b6-94a3-d43ce8d16293 749f88d5-cbae-40b8-bcfc-e573ddc772fa)
# tf-staging, fixed part: Key Vault Secrets User, Storage Blob Data Contributor, Storage Blob Data Reader, Monitoring
# Metrics Publisher. The kill switch role is a custom role with a per-subscription ID and is appended by the bootstrap.
ABAC_APP_ROLES=(4633458b-17de-408a-b874-0445c86b69e6 ba92f5b4-2d11-453d-a403-e96b0029c9fe 2a2b9908-6ea1-4ae2-8e65-a410df84e7d1 3913510d-42f4-4e42-8a64-420c390055eb)

# Joins its arguments as "a, b, c", the format of a GuidEquals list.
abac_guid_list() { local IFS=,; local s="$*"; echo "${s//,/, }"; }
