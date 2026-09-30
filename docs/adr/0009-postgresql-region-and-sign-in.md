# 9. PostgreSQL in Sweden Central, Entra ID sign-in only

- Status: accepted (decided by the owner on 2026-09-30)
- Date: 2026-09-30

## Context

Phase 3 moves the data layer to Azure Database for PostgreSQL Flexible Server. On 2026-09-30,
`az postgres flexible-server list-skus` reported for this subscription (offer FreeTrial_2014-09-01): Germany
West Central "Provisioning is restricted in this region" with `OfferRestricted = Enabled`, no server editions and
no versions; West Europe restricted in the same way; Sweden Central (`OfferRestricted = Disabled`), North Europe,
France Central, Poland Central and Switzerland North offer Standard_B1ms with versions 11 to 18. Compute already runs in Sweden Central (ADR 8), and ADR 8 named a chatty database connection
across regions as the real cost of splitting.

## Decision

- The database runs in `swedencentral`, next to compute. The location policy gets a database exception
  (`databaseLocations`, `databaseTypes`) that allows PostgreSQL flexible servers there and nowhere else outside
  Germany West Central.
- Burstable B1ms, 32 GB, 7 days of backups, no high availability, no geo-redundant backup, no storage auto-grow.
- Sign-in with Entra ID only. Password authentication is disabled at creation; the policy
  `deny-pg-password-auth` refuses anything else (ADR 3, ADR 6).
- Two Entra administrators and no group: the migration identity, which creates roles and maps workload
  identities, and the owner for break-glass access. The pipeline identity has no Microsoft Graph write rights,
  so it could not maintain a group, and a flexible server accepts several administrators.
- Terraform creates the server, the administrators, the TLS settings and one firewall rule. The migration job
  creates the database, its roles and the mapping of each workload identity to a role, so schema ownership
  never depends on who ran Terraform.
- Firewall: the rule "Azure services" (0.0.0.0) and nothing else. Container Apps on the Consumption profile
  without a VNet have no stable outbound address, so an address list would break at the next platform change.
  The boundary is the Entra token (ADR 6). The access test opens a rule for the runner's address for the
  duration of the test only.
- TLS: `require_secure_transport = on`, `ssl_min_protocol_version = TLSv1.2`; clients use `verify-full`
  against the system trust store.

## Consequences

- Data at rest is in Sweden, still in the EU. The privacy text says "EU" and not "Germany" while this holds.
- Any Azure customer's service can open a TCP connection to the server. Without a token of a mapped identity
  it cannot sign in, which the weekly access test proves.
- Production decides its region again after the switch to pay-as-you-go (plan 05): if Germany West Central
  opens, the choice is between moving data there and keeping one region for compute and data.
- Price, Retail Prices API, swedencentral, 2026-09-30, EUR: B1ms 0.0171 per hour, storage 0.1176 per GB and
  month, so ca. 16 per month outside the free-account grant.
