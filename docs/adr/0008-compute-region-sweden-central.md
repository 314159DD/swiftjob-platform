# 8. Compute in Sweden Central, data in Germany West Central

- Status: accepted
- Date: 2026-09-30
- Supersedes: [ADR 7](0007-compute-region.md)

## Context

ADR 7 moved the Container Apps compute layer to `westeurope` because `germanywestcentral` had no capacity. The first
apply there failed with `RequestDisallowedByAzure`: Azure applies a platform policy (`sys.blockwesteurope`) that
blocks new customers in West Europe for this subscription type. It is not our policy and cannot be exempted.

A second attempt in `germanywestcentral` (a throwaway environment, deleted right after) failed as well. The activity
log reports the location as ineligible for this subscription, so waiting for capacity is not a plan.

ARM validation against the other EU regions showed no platform block for `swedencentral` and `northeurope`; only our
own `allowed-locations` policies refused them.

## Decision

- The compute layer (Container Apps environment, container apps, container app jobs) runs in `swedencentral`.
- `northeurope` is allowed as a fallback in the same policy exception, so a second capacity problem needs a
  one-variable change in the private configuration and no policy change.
- Data stays in `germanywestcentral`, unchanged from ADR 7 (Key Vault, storage, identities, Application Insights, the
  kill switch and, later, PostgreSQL).
- Phase 1 `allowed-locations` lists both regions, because it allows regions for every type. `allowed-locations-v2`
  narrows them to the compute types once it is enforced.
- The policy tests move with the decision: a Container Apps environment in `swedencentral` must validate, a storage
  account in `swedencentral` must be refused.

## Consequences

- Both regions are in the EU. The promise to users (EU only, data at rest in Germany) still holds.
- Latency between Sweden Central and Germany West Central is higher than from West Europe, roughly 20 to 30 ms per
  round trip. The workloads are batch jobs and a small web app with few Key Vault and storage calls, so this is
  acceptable. Revisit when PostgreSQL arrives in phase 3: a chatty database connection across regions is the real
  cost, and the database may have to follow compute or compute may have to come back.
- Inter-region traffic stays at cents per month at staging volumes, as in ADR 7.
- Until `allowed-locations-v2` is enforced, phase 1 lets every type use the two new regions. The phase 2 compliance
  review catches anything placed there by mistake.
- Moving back means changing `compute_location` and re-creating the environment, as in ADR 7.
- The trial subscription allows one Container Apps environment in total, not one per region
  (`MaxNumberOfGlobalEnvironmentsInSubExceeded`). Until the subscription moves to pay-as-you-go, staging holds the
  only one. The one-time VNet proof (plan 02c) and production need that switch first, or the VNet proof temporarily
  replaces the staging environment.
