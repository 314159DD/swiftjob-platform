# 10. Customer sign-in in a separate external tenant, one per environment

- Status: accepted (decided by the owner on 2026-10-02)
- Date: 2026-10-02

## Context

Customers sign in through Microsoft Entra External ID. The design keeps workforce and customer identities in
separate directories (ADR 2, management groups): operators and pipelines live in the workforce tenant,
customers never do. A customer tenant is an external tenant, an Azure resource of type
`Microsoft.AzureActiveDirectory/ciamDirectories` in a resource group. Its location is a geography, not an Azure
region. On 2026-10-02, `az provider show -n Microsoft.AzureActiveDirectory` listed for that type: Global,
United States, Europe, Asia Pacific, Australia, Japan. The enforced `allowed-locations-v2` assignment (Germany West
Central and `global`, plus the exceptions of ADR 8 and ADR 9) would refuse every one of them except `global`,
which is not offered for a tenant that holds customer data in Europe.

## Decision

- One external tenant per environment: staging now, production in the production cutover. Test accounts and real
  customers are never mixed in one directory.
- Country/Region of the tenant is Germany, which places it in the Europe geography. The setting cannot be changed
  after creation.
- The tenant is linked to the subscription for billing and sits in the resource group `rg-swiftjob-identity`.
- The location policy gets an identity exception: `identityTypes` and `identityLocations` allow exactly the type
  `Microsoft.AzureActiveDirectory/ciamDirectories` in exactly the geography `europe` and nothing else outside
  Germany West Central. The policy compares the normalised form (lower case, no spaces).
- The owner creates the tenant in the admin center. Creation needs the Tenant Creator role on the subscription or
  a resource group, and no pipeline identity holds it (ADR 5, no elevated tenant access for automation).
- The resource provider `Microsoft.AzureActiveDirectory` is registered by the owner by hand (the Terraform
  provider registers nothing, see the bootstrap rules). Until it is registered, validation of a tenant template
  fails with `MissingSubscriptionRegistration`, which the policy test never accepts as a pass.
- App registrations inside the tenant are Terraform in a separate identity layer with its own state and its own
  pipeline identities, so a pull request plan never holds write rights (ADR 1).

## Consequences

- Customer sign-in data lives in the Europe geography, in the EU.
- Billing is by monthly active users on the subscription: the first 50,000 are free, administrators of the tenant
  count as users. Upgrading the subscription from a trial to pay-as-you-go keeps the subscription id, so the link
  survives.
- The policy now has one more parameter pair. The policy test proves both sides: a tenant template in `Europe`
  validates, the same template in `United States` is refused by `allowed-locations-v2`.
- A tenant is not deleted with its resource group in one step; teardown is an owner action in the admin center.

## Alternatives

- A 30-day trial tenant without a subscription: 10,000 objects, 20 requests per second, cannot be extended and
  expires. Fine for a first look, not for staging.
- One tenant for all environments: staging test accounts and real customers in one directory, and one set of
  app registrations whose redirect URLs mix both.
- Widening the global location list to the other geographies: every resource type could then leave Europe.
