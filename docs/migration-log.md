# Migration log

The move of SwiftJob to Azure, phase by phase. Each phase appends an entry. The plan is in the roadmap in the
[README](../README.md).

## Phase 0 and 1 (2026-09-29 to 2026-09-30): landing zone in place

What exists now:

- A Terraform state account `stswiftjobtf3100a5` in `rg-swiftjob-tfstate`, without shared keys and without
  public access, with versioning and 30 day soft delete. Containers `platform`, `staging` and `prod`.
- The management group tree `mg-swiftjob` with `mg-platform`, `mg-workloads` (`mg-prod`, `mg-nonprod`) and
  `mg-sandbox`. The subscription sits under `mg-workloads`.
- Three GitHub OIDC identities, `swiftjob-tf-plan`, `swiftjob-tf-platform` and `swiftjob-policy-test`, and
  three GitHub environments, `plan`, `platform` and `policy-test`.
- 12 policy assignments and 1 custom policy definition at `mg-swiftjob`, enforced since 2026-09-30: allowed
  regions for resources and resource groups, required tags on resource groups, no storage shared keys, Key
  Vault RBAC permission model, cost guards on resource types, VM sizes and SKUs, and audit-log diagnostics to
  the central workspace (ADR 3).
- The central Log Analytics workspace `log-swiftjob-platform` (30 days retention, 0.1 GB daily cap) in
  `rg-swiftjob-platform`.
- A subscription budget of 25 EUR per month with alerts at 50 % and 80 % actual and 100 % forecast.
- CI on every pull request (Terraform checks, script tests, leak check, plan), an approved apply with an
  idempotency check after each merge, a nightly drift check and a weekly policy test.
- Branch protection on `main` requiring the four checks, enforced for administrators.
- In each of the three private application repositories: the tag `pre-azure-2026-09-30`, the branch
  `azure-migration` and an offline bundle.
- The repository has been public since 2026-09-29, after a leak check of all files and commit messages.

Decisions taken in this phase: Terraform (ADR 1), the hierarchy (ADR 2), evaluate before enforcing and no
custom VNet before revenue (ADR 3), public platform with private product (ADR 4).

Results and run IDs are in [verification.md](verification.md).

## Phase 2a (2026-09-30): hardened pipeline, phase 2 policies enforced, staging infrastructure without apps

What exists now:

- Plan output rules: every Terraform command runs through `scripts/tf-layer.sh`. Layers with private inputs never
  print Terraform errors in a public log (ADR 5).
- `tf-plan` only reads: Reader plus Storage Blob Data Reader on the state containers, and the custom role
  `swiftjob-plan-reader` for the workload layers. A weekly rights test proves it.
- A fourth pipeline identity, `swiftjob-tf-staging`, with Contributor on the staging and network test resource
  groups and role assignments limited by an ABAC condition (ADR 5).
- A private configuration repository, `314159DD/swiftjob-platform-config`, read by the public workflows through a
  read-only deploy key. Only commits on its main branch can be deployed.
- Phase 2 policies enforced: `allowed-locations-v2` (replacing `allowed-locations`), `deny-pg-password-auth`,
  `deny-network-cost`, plus audits for public network access and Container Apps (ADR 3, ADR 6).
- The staging environment `rg-swiftjob-staging` without any app: Container Apps environment `cae-swiftjob-staging`
  in `swedencentral`, Key Vault, storage, monitoring and a kill switch, all in Germany West Central except the
  compute. Nothing has an hourly price.
- Staging plan on pull requests, apply on merge or dispatch, nightly drift for both layers.

Decisions taken in this phase: workload layer and private configuration (ADR 5), no custom VNet before revenue
(ADR 6), compute region (ADR 7, superseded by ADR 8: compute in `swedencentral`, `northeurope` as fallback).

Results and run IDs are in [verification.md](verification.md).

## Phase 3 (2026-10-01 to 2026-10-02): database on Azure

- Azure Database for PostgreSQL flexible server in `swedencentral` (ADR 9), Entra sign-in only, TLS 1.2 enforced,
  no public access beyond the Azure services rule. Staging only.
- A migration job runs the versioned schema as the migration identity and creates the application roles; it is
  idempotent (second run applies 0). The database layer uses per-user row-level security, proven by an isolation
  probe that also runs as a job.
- The application no longer reads or writes its data through the old hosted database; the old identity provider is
  used for sign-in only until phase 4.
- Evidence (access test 14/14, isolation probe 31/31, product flows, break-glass, peak connections 12) is in
  [verification.md](verification.md). The server cost check is pending until 2026-10-04.
- Deferred to the owner: production export and the full data import (phase 5).
