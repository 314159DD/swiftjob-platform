# 6. No custom virtual network before revenue

- Status: accepted
- Date: 2026-09-30

## Context

Network isolation is the usual answer to "how do we protect the data services". It has a price. A Container Apps
environment with a custom virtual network brings a Standard load balancer and public IP addresses that are billed by
the hour, whether or not the app receives traffic. Until there is customer data and revenue, that fixed cost buys
little.

## Decision

- No custom VNet in any environment before revenue.
- The price, from the Azure Retail Prices API, region `germanywestcentral`, 2026-09-30, in EUR: a Standard load
  balancer 0.0215 per hour and two public IPs 0.0043 per hour each. That is about 22 per month per environment.
  The management fee of the environment (0.1116 per hour) also applies with a Dedicated profile, a private endpoint
  or planned maintenance.
- Identity is the boundary instead:
  - Key Vault uses the RBAC permission model. A request needs an Entra token and a role assignment. Access
    policies are denied (ADR 3).
  - Storage is reached through Entra ID only. Shared keys are denied by policy.
  - The database (plan 03) is PostgreSQL with Entra ID sign-in only. The policy `deny-postgres-password-auth`
    refuses a server that allows password sign-in.
- The policy `deny-network-cost` enforces the decision. At `mg-workloads` it denies a Container Apps environment with
  a virtual network, a workload profile other than Consumption, a Standard load balancer and a private endpoint.
  The throwaway test groups are exempt: `rg-swiftjob-nettest`, its infrastructure group
  `rg-swiftjob-nettest-infra` (created by Container Apps itself) and the network test group of the other project in
  the subscription.
- Public network access on Key Vault, storage and PostgreSQL is audited, not denied, in production (`mg-prod` and
  the production resource group). The audit makes the deviation visible until the switch below.
- Plan 02c builds a VNet environment once in the exempt group, proves it works with the same module and deletes it
  after the test. The proof is short-lived, so it costs little, and it shows that the switch is a change of configuration and
  not a redesign.

## When to switch

When the platform holds customer data and earns revenue that makes 22 EUR per month per environment small, the
custom VNet comes in with private endpoints for Key Vault, storage and the database. The `deny-network-cost` policy
then changes in a pull request, and the audits of public network access turn into denies.

## Consequences

- Traffic to platform services crosses their public endpoints, protected by TLS and by identity. That is a weaker
  position than private networking. It is a chosen trade against the monthly cost, not an oversight.
- A stolen token is more dangerous without a network boundary. Short-lived federated credentials, no shared keys and
  the narrow roles of ADR 5 are what reduce that risk.
- Checkov findings for missing network rules and private endpoints on the workload resources are skipped in code
  with a reference to this ADR, so the reason is next to the code.
- The switch later is a planned change with a known price, and no design has to be undone.
