# SwiftJob platform

The Azure platform for [SwiftJob](https://swiftjob.de), defined in Terraform. This repository holds the landing
zone: management groups, policy, identities, budget, state and the pipelines that change them. The product code
(a web app, an API and scheduled jobs) lives in three private repositories. Everything here was applied to a
real subscription and checked, with the results and run IDs in [docs/verification.md](docs/verification.md).

## Landing zone

```
mg-swiftjob            all policy assignments live here
  mg-platform
  mg-workloads         the subscription sits here for now
    mg-prod
    mg-nonprod
  mg-sandbox           excluded from the cost guards
```

Data region is `germanywestcentral`; Container Apps compute and the PostgreSQL server run in `swedencentral` ([ADR 9](docs/adr/0009-postgresql-region-and-sign-in.md)), with `northeurope` as fallback ([ADR 8](docs/adr/0008-compute-region-sweden-central.md), which supersedes [ADR 7](docs/adr/0007-compute-region.md)). The tree is defined in `platform/management-groups.tf` ([ADR 2](docs/adr/0002-management-group-hierarchy.md)).

### Identities

All four use GitHub OIDC federation. There is no secret. Each is tied to a GitHub environment (`tf-staging` to two, `staging` and `nettest`; `tf-plan` is also trusted from the
main branch of the private configuration repository)
([ADR 1](docs/adr/0001-terraform-layered-state-and-identities.md)).

| Identity | Environment | What it can do |
|---|---|---|
| `swiftjob-tf-plan` | `plan` | Read on `mg-swiftjob` and the subscription, read on the three state containers (no write) and the custom `swiftjob-plan-reader` role on the workload resource groups. Plans are lock-free. Runs `terraform plan` on pull requests and for the drift check |
| `swiftjob-tf-platform` | `platform`, required reviewer, `main` only | Applies the platform layer: management groups, policy, the platform resource group, the budget, and role assignments limited by an ABAC condition to two logging roles |
| `swiftjob-policy-test` | `policy-test`, `main` only | Validates test templates in the platform resource group, with write on exactly the tested resource types |
| `swiftjob-tf-staging` | `staging`, `nettest`, `main` only | Applies the staging workload layer: Contributor on the staging and network test resource groups, write on its own state container only, Log Analytics Contributor on the central workspace, and role assignments limited by an ABAC condition to a short list of data roles for service principals ([ADR 5](docs/adr/0005-staging-workload-identity.md)) |

### Policies

22 assignments in total, all enforced or audit-only by design ([ADR 3](docs/adr/0003-policy-rollout-do-not-enforce-first.md)).

| Policy | Effect | Reason |
|---|---|---|
| `allowed-locations-v2` | Deny | Keeps resources in Germany West Central and `global`. The two regions Static Web Apps need are allowed for that type only, `swedencentral` and `northeurope` for the Container Apps types only ([ADR 8](docs/adr/0008-compute-region-sweden-central.md)), the customer identity tenant in the Europe geography only ([ADR 10](docs/adr/0010-customer-identity-tenant.md)). Replaces `allowed-locations` |
| `allowed-rg-locations` | Deny | Resource group regions. Unchanged in phase 2 because the resource groups of the other project live in West Europe |
| `require-rg-tag-project`, `-env`, `-owner` | Deny | Every resource group says what it is for and who owns it |
| `deny-storage-shared-key` | Deny | Storage is reached through Entra ID, never through account keys |
| `deny-kv-access-policies` | Deny | Key vaults use the RBAC permission model |
| `deny-costly-types` | Deny | No firewall, application gateway, Bastion, VPN or ExpressRoute gateway, NAT gateway, managed Kubernetes or VM scale set |
| `allowed-vm-sizes` | Deny | Small burstable VM sizes only |
| `deny-costly-skus` (custom) | Deny | No Front Door Premium, no API Management above Consumption and Developer, PostgreSQL limited to burstable SKUs |
| `diag-keyvault`, `diag-postgres` | DeployIfNotExists | Audit logs go to the central Log Analytics workspace without per-resource setup |
| `deny-pg-password-auth` (custom) | Deny | PostgreSQL flexible servers use Entra ID sign-in only |
| `deny-network-cost` (custom, at `mg-workloads`) | Deny | No VNet Container Apps environment, no dedicated workload profile, no Standard load balancer, no private endpoint. The throwaway network test groups are exempt ([ADR 6](docs/adr/0006-no-virtual-network-before-revenue.md)) |
| `audit-pna-keyvault`, `-storage`, `-postgres` | Audit | Public network access is visible in production until the VNet switch |
| `audit-aca-identity`, `-https` | Audit | Container Apps without a managed identity or without HTTPS only |

The three cost guards skip `mg-sandbox`.

## How changes flow

1. A pull request runs five required checks: `Terraform checks` (format, validate, tflint, Checkov), `Script
   tests`, `Leak check`, `Plan (platform)` and `Plan (staging)`. The plan is posted as a per-type summary of resource types and counts.
2. After the merge, the `Apply` workflow waits for a reviewer's approval on the `platform` environment, plans,
   applies and then plans again. The second plan must report no changes.
3. A nightly `Drift` workflow runs a plan and goes red when Azure differs from the code.
4. A weekly `Policy test` workflow validates templates that must be refused and one that must pass.

The staging workload layer (`environments/staging`, built from `modules/workload`) follows the same path:

5. The pull request plans both layers, `Plan (platform)` and `Plan (staging)`.
6. A merge that changes the module or the staging root applies staging. So does a configuration dispatch from the
   private configuration repository after a merge there. Apply runs a second plan that must be empty.
7. The nightly `Drift` workflow checks both layers.
8. A weekly `Rights test` proves that `tf-plan` cannot write state and that `tf-staging` cannot touch production or
   grant itself more or grant a data role to a user. The user check needs the repository variable
   `RIGHTS_TEST_USER_ID` (object ID of a user account, set with `gh variable set`); without it the test fails.

Product configuration (names, settings, schedules, image digests) lives in a private repository. This repository
holds only the code that consumes it ([ADR 5](docs/adr/0005-staging-workload-identity.md)).

Workflows pin every action to a full commit SHA and use minimal permissions. Plan and apply output never goes to the log. Terraform errors are redacted for the platform layer and withheld for layers with private inputs; the full text of a plan error is only available in the private Diagnose workflow, which re-plans. An apply error cannot be replayed there, so the withheld message is followed by a summary line built only from resource types, Azure error codes and HTTP status codes (`withheld error summary: types=[...] codes=[...] status=[...]`).

Known behaviour: an apply can fail part way, for example on a transient Azure error after secrets were loaded minutes before. Terraform records every finished change in state, so rerunning the failed job (`gh run rerun <id> --failed`) plans again from the new state and applies only the rest. The second plan and the smoke test then confirm the result. Read the summary line first: a code such as `AuthorizationFailed` or `InvalidTemplate` will fail again and needs a fix, not a rerun.

### Database migrations in the apply

`Apply staging` runs the database migrations itself, before the apps are updated: plan, then `scripts/db-migrate.sh staging`
(a targeted apply of the db-migrate job to the new image, one execution, polled until it succeeds or fails), then plan
again, apply, verify, smoke test. A failed or timed-out migration stops the workflow with the apps still on the previous
image. Rerunning the failed job is safe because the migrations are idempotent. The script takes the environment name, so
the production apply will reuse it (prod layer added with plan 05 Task 3, `feat/prod-layer`).

This order needs the expand/contract rule: every migration must work with the app code that is running while it
executes (add first; drop or rename only in a later release, after no code uses the old shape).

## Cost guardrails

- A subscription budget of 25 EUR per month warns at 50 % and 80 % of actual spend and at 100 % of forecast.
  It only warns.
- Policies deny the resource types and SKUs that carry a high fixed monthly price, for example Azure Firewall
  Standard (about 783 EUR per month) and Front Door Premium (about 283 EUR per month). The price basis is in
  ADR 3.
- The central Log Analytics workspace has a daily ingestion cap of 0.1 GB.

## Deliberate decisions

- No custom virtual network before revenue. For Container Apps a custom VNet adds a load balancer and two public
  IPs, about 22 EUR per month per environment. Identity is the boundary for now: Entra ID, role assignments and
  policy. The reasoning and the numbers are in [ADR 6](docs/adr/0006-no-virtual-network-before-revenue.md).
- Only three things run by hand from the owner's machine, because Terraform needs them to exist first or
  because they are rare privileged acts: `scripts/bootstrap.sh` (state, root management group, identities,
  provider registration), `scripts/configure-github.sh` (environments, branch protection) and
  `scripts/move-subscription.sh` (moving the subscription between management groups). The pipeline holds no
  permission for any of them, and the bootstrap has no fallback to elevated tenant access.
- The repository is public and the product is private. A leak check enforces the line ([ADR 4](docs/adr/0004-public-platform-private-product.md)).

## Documentation

- [ADR 1: Terraform with layered state and separate identities](docs/adr/0001-terraform-layered-state-and-identities.md)
- [ADR 2: Management group hierarchy](docs/adr/0002-management-group-hierarchy.md)
- [ADR 3: Policy rollout, evaluate first, then enforce](docs/adr/0003-policy-rollout-do-not-enforce-first.md)
- [ADR 4: Public platform repository, private product repositories](docs/adr/0004-public-platform-private-product.md)
- [ADR 5: The workload layer, private configuration and the staging pipeline identity](docs/adr/0005-staging-workload-identity.md)
- [ADR 6: No custom virtual network before revenue](docs/adr/0006-no-virtual-network-before-revenue.md)
- [ADR 7: Compute in West Europe, data in Germany](docs/adr/0007-compute-region.md) (superseded)
- [ADR 8: Compute in Sweden Central, data in Germany West Central](docs/adr/0008-compute-region-sweden-central.md)
- [ADR 9: PostgreSQL in Sweden Central, Entra ID sign-in only](docs/adr/0009-postgresql-region-and-sign-in.md)
- [ADR 10: Customer sign-in in a separate external tenant](docs/adr/0010-customer-identity-tenant.md)
- [Verification log](docs/verification.md)
- [Migration log](docs/migration-log.md)

## Roadmap

Phases 0 and 1 are done. Phase 2a (hardened pipeline, phase 2 policies enforced, staging infrastructure without
apps) is done. Phase 3 (database on Azure, migration job, staging proven) is done except the owner-gated production
export and import. What follows:

- Phase 2: run the web app, the API and the scheduled jobs on Azure Container Apps.
- Phase 3: move the database to Azure Database for PostgreSQL.
- Phase 4: move sign-in to Microsoft Entra External ID.
- Phase 5: production cutover to Azure.
- Phase 6: retire the old hosting.
- Phase 7: one subscription per environment, under `mg-prod` and `mg-nonprod`.

Each phase appends to the [migration log](docs/migration-log.md).
