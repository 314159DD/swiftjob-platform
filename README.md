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

Region is `germanywestcentral`. The tree is defined in `platform/management-groups.tf` ([ADR 2](docs/adr/0002-management-group-hierarchy.md)).

### Identities

All three use GitHub OIDC federation. There is no secret. Each is tied to one GitHub environment
([ADR 1](docs/adr/0001-terraform-layered-state-and-identities.md)).

| Identity | Environment | What it can do |
|---|---|---|
| `swiftjob-tf-plan` | `plan` | Read on `mg-swiftjob` and the subscription, read on the three state containers. Plans are lock-free. Runs `terraform plan` on pull requests and for the drift check |
| `swiftjob-tf-platform` | `platform`, required reviewer, `main` only | Applies the platform layer: management groups, policy, the platform resource group, the budget, and role assignments limited by an ABAC condition to two logging roles |
| `swiftjob-policy-test` | `policy-test`, `main` only | Validates test templates in the platform resource group, with write on exactly the tested resource types |

### Policies

12 assignments at `mg-swiftjob`, enforced ([ADR 3](docs/adr/0003-policy-rollout-do-not-enforce-first.md)).

| Policy | Effect | Reason |
|---|---|---|
| `allowed-locations` | Deny | Keeps resources in Germany West Central, plus `global` and the two regions Static Web Apps need |
| `allowed-rg-locations` | Deny | Same for resource groups |
| `require-rg-tag-project`, `-env`, `-owner` | Deny | Every resource group says what it is for and who owns it |
| `deny-storage-shared-key` | Deny | Storage is reached through Entra ID, never through account keys |
| `deny-kv-access-policies` | Deny | Key vaults use the RBAC permission model |
| `deny-costly-types` | Deny | No firewall, application gateway, Bastion, VPN or ExpressRoute gateway, NAT gateway, managed Kubernetes or VM scale set |
| `allowed-vm-sizes` | Deny | Small burstable VM sizes only |
| `deny-costly-skus` (custom) | Deny | No Front Door Premium, no API Management above Consumption and Developer, PostgreSQL limited to burstable SKUs |
| `diag-keyvault`, `diag-postgres` | DeployIfNotExists | Audit logs go to the central Log Analytics workspace without per-resource setup |

The three cost guards skip `mg-sandbox`.

## How changes flow

1. A pull request runs four required checks: `Terraform checks` (format, validate, tflint, Checkov), `Script
   tests`, `Leak check` and `Plan (platform)`. The plan is posted as a per-type summary of resource types and counts.
2. After the merge, the `Apply` workflow waits for a reviewer's approval on the `platform` environment, plans,
   applies and then plans again. The second plan must report no changes.
3. A nightly `Drift` workflow runs a plan and goes red when Azure differs from the code.
4. A weekly `Policy test` workflow validates templates that must be refused and one that must pass.

Workflows pin every action to a full commit SHA and use minimal permissions. Plan and apply output never goes to the log. Terraform errors are redacted for the platform layer and withheld for layers with private inputs; the full text is only available in a private workflow.

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
  policy. The reasoning and the numbers are in ADR 3.
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
- [Verification log](docs/verification.md)
- [Migration log](docs/migration-log.md)

## Roadmap

Phases 0 and 1 (this repository) are done. What follows:

- Phase 2: run the web app, the API and the scheduled jobs on Azure Container Apps.
- Phase 3: move the database to Azure Database for PostgreSQL.
- Phase 4: move sign-in to Microsoft Entra External ID.
- Phase 5: production cutover to Azure.
- Phase 6: retire the old hosting.
- Phase 7: one subscription per environment, under `mg-prod` and `mg-nonprod`.

Each phase appends to the [migration log](docs/migration-log.md).
