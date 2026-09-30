# 3. Policy rollout: evaluate first, then enforce

- Status: accepted
- Date: 2026-09-30

## Context

The policies are assigned at the root management group, so they apply to the other project in the subscription
too. A deny policy that breaks a running deployment is a bad way to find out what already exists. The
policies also have a second job: keeping expensive resource types out of a subscription that is meant to cost
almost nothing until there is revenue.

## Decision

- Every assignment reads `enforce = var.enforce_policies`. The variable started as `false`, which is
  `DoNotEnforce`: Azure evaluates compliance and reports it, and nothing is denied.
- With enforcement off, the existing resource groups were tagged (tags merged, not replaced) and the compliance
  report was reviewed per non-compliant resource. The scan on 2026-09-30 showed 0 non-compliant resources for
  every evaluated assignment. Enforcement was then switched on in PR #5. Its plan showed 12 policy assignments
  to update and nothing else. Apply
  [36651226675](https://github.com/314159DD/swiftjob-platform/actions/runs/36651226675) succeeded and its
  second plan had no changes.
- The other project deployed cleanly under the enforced policies
  ([36652938651](https://github.com/314159DD/azure-cloud-resume/actions/runs/36652938651), staging and
  production, both smoke tests OK).
- A policy that silently stops working is as bad as one that is too strict, so there is a weekly test
  (`scripts/policy-test.sh`, workflow `Policy test`). It validates four templates that must be refused and
  names the policy that refused each one, plus a control template that must pass. The control matters: if
  everything is refused, the test would be red for the wrong reason. The test has an identity of its own
  because validation needs write on the tested types (ADR 1).
- The cost guards. Prices are from the Azure Retail Prices API on 2026-09-30, region `germanywestcentral`, in
  EUR per month:

  | Resource | Approximate price | Guard |
  |---|---|---|
  | Azure Firewall Basic, Standard, Premium | 248, 783, 1,097 | type denied |
  | Application Gateway WAF_v2 | 226 plus capacity | type denied |
  | Front Door Premium | 283 | SKU denied |
  | API Management Basic v2, Standard v2 | 129, 601 | SKUs other than Consumption and Developer denied |
  | Standard Load Balancer | 15.70 | none |
  | Public IP | 3.14 | none |

  The same policies also deny Bastion, VPN and ExpressRoute gateways, NAT gateways, managed Kubernetes and VM
  scale sets. PostgreSQL flexible servers are limited to the burstable B1ms, B2s and B2ms SKUs, and virtual
  machines to a short list of small burstable sizes. The sandbox management group is excluded from these
  cost guards.
- Alongside the policies, a subscription budget of 25 EUR per month warns at 50 % and 80 % of actual spend and
  at 100 % of forecast spend. The central Log Analytics workspace has a daily ingestion cap of 0.1 GB.
- No custom virtual network before revenue. The Container Apps environment management meter (0.1116 EUR per
  hour) only applies with a Dedicated profile, a private endpoint or planned maintenance. A custom VNet adds a
  Standard Load Balancer (0.0215 EUR per hour) and two public IPs (0.0043 EUR per hour each), about 22 EUR per
  month per environment (Retail Prices API, `germanywestcentral`, 2026-09-30). Identity is the boundary
  instead: access goes through Entra ID and role assignments, and storage shared keys are denied by policy.
  Network isolation stays possible later. The monthly cost is the reason it is off today.

## Consequences

- The policy set is reviewed against reality before it can block anything, and the rollout is a one-line
  change in the code with its own plan and apply.
- The policy test was red before enforcement (run
  [36651056141](https://github.com/314159DD/swiftjob-platform/actions/runs/36651056141): all four forbidden
  templates validated, and so did the control) and green after
  ([36652775932](https://github.com/314159DD/swiftjob-platform/actions/runs/36652775932)). The test ran 15 minutes
  after the apply, because Azure takes a while to start enforcing.
- The budget only warns. It does not stop spending. Nothing stops spending automatically yet; each workload adds its own limits in later phases.
- Without a custom VNet, traffic to platform services crosses their public endpoints, protected by identity
  and TLS. That is a weaker position than private networking and it is a chosen trade against about 22 EUR per
  month per environment.
- A legitimate need for a denied resource type means changing the policy in a pull request. The price table is
  the first thing to check when that comes up.

## Phase 2

Phase 2 (workload infrastructure, ADR 5) added policies for the new resource types. They went through the same
rollout: assigned with `enforce_phase2_policies = false`, reviewed against the compliance report, then enforced.

| Assignment | Effect | Scope |
|---|---|---|
| `allowed-locations-v2` | Deny | `mg-swiftjob`. Germany West Central and `global` for every type, the Static Web Apps regions for that type only, the compute regions (`swedencentral`, `northeurope`) for the three Container Apps types only ([ADR 8](0008-compute-region-sweden-central.md)) |
| `deny-pg-password-auth` | Deny | `mg-swiftjob`. PostgreSQL flexible servers must use Entra ID only |
| `deny-network-cost` | Deny | `mg-workloads`, without the network test groups. No VNet Container Apps environment, no workload profile other than Consumption, no Standard load balancer, no private endpoint ([ADR 6](0006-no-virtual-network-before-revenue.md)) |
| `audit-pna-keyvault`, `-storage`, `-postgres` | Audit | `mg-prod` and the production resource group. Public network access stays visible until the VNet switch |
| `audit-aca-identity`, `-https` | Audit | `mg-workloads`. Container Apps without a managed identity or without HTTPS only |

- Compliance before enforcement (2026-09-30): every evaluated assignment showed 0 non-compliant resources. The
  A1 project (Static Web App in `eastus2`, network test with a private endpoint in `rg-cloudresume-nettest`) is not
  affected: the Static Web Apps exception covers the first and the network test group is exempt from
  `deny-network-cost`.
- The policy test gained templates for the new policies. Before enforcement, run
  [36668175381](https://github.com/314159DD/swiftjob-platform/actions/runs/36668175381) was red as intended: the 3
  old templates passed, the 6 new forbidden templates validated and were reported "not refused", and the 2 controls
  passed. After enforcement, run [36691827570](https://github.com/314159DD/swiftjob-platform/actions/runs/36691827570) refused all 10 forbidden templates but reported the Container Apps control as refused: the provider rejected it because a trial subscription allows one Container Apps environment and staging holds it. Policy is evaluated before that preflight, so the test now accepts exactly that quota error when no policy refused the template (PR #23). Run [36693925274](https://github.com/314159DD/swiftjob-platform/actions/runs/36693925274) is green, 13 of 13.
- The A1 project stays green under the enforced policies: guardrail verification [36691831989](https://github.com/314159DD/azure-cloud-resume/actions/runs/36691831989), private network test RUN_ID_A1_NETWORK.
- `allowed-locations` (phase 1) is replaced by `allowed-locations-v2`. The old assignment allowed the compute and
  Static Web Apps regions for every type. The v2 assignment allows them only for the types that need them. It was
  removed in PR #21, platform apply
  [36689799328](https://github.com/314159DD/swiftjob-platform/actions/runs/36689799328).
- Resource group regions: `allowed-rg-locations` was left unchanged. The resource groups of the A1 project live in
  `westeurope`, and a Deny on resource group locations would break its deployments. Resources are limited by
  `allowed-locations-v2`, so a resource group in `westeurope` can hold nothing but the types that region is allowed
  for.
