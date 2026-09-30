# 7. Compute in West Europe, data in Germany West Central

- Status: superseded by [ADR 8](0008-compute-region-sweden-central.md)
- Date: 2026-09-30

## Context

The workload layer needs a Container Apps environment. On 2026-09-30 Azure refused to create one in
`germanywestcentral` and returned `ManagedEnvironmentCapacityHeavyUsageError` (`AKSCapacityHeavyUsage`). This is a
regional capacity shortage on the provider side, not a quota or a configuration problem, and there is no date for
when it ends.

## Decision

- The compute layer moves to `westeurope` (EU, Netherlands): the Container Apps environment, the container apps and
  the container app jobs. The workload module gets a `compute_location` variable for this.
- Everything that stores data stays in `germanywestcentral`: Key Vault, storage, managed identities, Application
  Insights, the kill switch logic app and, later, PostgreSQL. Data at rest stays in Germany.
- The policy `allowed-locations-v2` gets a second exception, next to the one for Static Web Apps. `westeurope` is
  allowed only for `Microsoft.App/managedEnvironments`, `Microsoft.App/containerApps` and `Microsoft.App/jobs`. Every
  other type is still limited to `germanywestcentral` and `global`.
- Staging defaults `compute_location` to `westeurope` in `environments/staging/variables.tf`, so it does not depend
  on the private configuration. The module default stays equal to `location`.
- The new policy parameters have defaults, so updating the definition never breaks the live assignment.
- A policy test template (`containerapps-env-westeurope`) proves the exception works. A storage account in `westeurope` must
  still be refused, which proves the exception is limited to the compute types. The tests for a storage account in
  `eastus2` and for an unlisted region still have to be refused.

## Consequences

- Both regions are in the EU, so the promise to users (EU only, data at rest in Germany) still holds. Data in transit
  and in memory is processed in the Netherlands.
- Calls from the apps to Key Vault and storage cross regions. Expect a few milliseconds of extra latency per call.
  The workloads are batch jobs and a small web app, so this is acceptable.
- Traffic between regions is billed. The Azure Retail Prices API (queried 2026-09-30) lists "Standard Inter-Region
  Data Transfer" at 0.0172 EUR per GB for both regions. At staging volumes (a few GB a month) this is cents.
- The kill switch and the budget stay in Germany and act on the container apps across regions. Nothing changes there.
- Moving compute back later means changing one variable and re-creating the environment. A Container Apps
  environment cannot change region in place.
- Revisit when capacity in `germanywestcentral` returns. Then set `compute_location` back, remove the policy
  exception (or keep it as a fallback) and record the change in a new ADR.
