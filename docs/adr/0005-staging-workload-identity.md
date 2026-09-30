# 5. The staging pipeline identity

- Status: accepted
- Date: 2026-09-30

## Context

The staging workload layer is applied by a pipeline identity (`swiftjob-tf-staging`, GitHub environments `staging`
and `nettest`, main branch only). It has to create resources and give the workload identities their data roles, and
it must not be able to make itself more powerful (ADR 1).

## Decision

Roles of `swiftjob-tf-staging`:

- Contributor on `rg-swiftjob-staging` and `rg-swiftjob-nettest`.
- Storage Blob Data Contributor on the `staging` state container only.
- Log Analytics Contributor on the central workspace only. Diagnostic settings, workspace-based Application Insights
  and log alert rules need it.
- Role Based Access Control Administrator on the two resource groups, with an ABAC condition. It may create role
  assignments only for these roles: Key Vault Secrets User, Storage Blob Data Contributor, Storage Blob Data Reader,
  Monitoring Metrics Publisher and `swiftjob-containerapp-stopper`. Only for principals of type `ServicePrincipal`,
  and never for its own principal ID. It may delete assignments of the same roles for service principals only.

`tf-plan` gets the custom role `swiftjob-plan-reader` on the staging and production resource groups. It adds the
refresh-only actions that Reader lacks (container app and job secret listing, the kill switch trigger URL).

The weekly rights test proves the refusals: production and platform changes, a role outside the list, a self-grant
of Key Vault Secrets User, a grant at subscription scope, a write to the platform state. Its control grants an
allowed role to a different identity and removes it again.

## Consequences

- Residual risk: Contributor on the staging resource group lets `tf-staging` deploy a workload whose identity holds
  Key Vault Secrets User, and so read the staging vault indirectly. The ABAC condition blocks the direct self-grant
  only. Changes to the staging layer therefore stay behind a merge to main in the private configuration repository.
- Residual risk: Log Analytics Contributor on the central workspace lets staging read all central logs, production
  included once it exists, and change the daily cap, retention or delete the workspace. The nightly platform drift
  shows a changed cap. To revisit with a narrower custom role before plan 05.
- `swiftjob-plan-reader` lets `tf-plan` list container app secrets. The workload modules must use Key Vault
  references only, so no secret value is ever stored in a container app definition.
- The bootstrap must keep the ABAC condition and the rights test in step. If Azure rejects an attribute in the
  condition, the finding is recorded here.
