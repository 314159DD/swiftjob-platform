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
- The budget only warns. It does not stop spending. Stopping is left to per-workload limits.
- Without a custom VNet, traffic to platform services crosses their public endpoints, protected by identity
  and TLS. That is a weaker position than private networking and it is a chosen trade against about 22 EUR per
  month per environment.
- A legitimate need for a denied resource type means changing the policy in a pull request. The price table is
  the first thing to check when that comes up.
