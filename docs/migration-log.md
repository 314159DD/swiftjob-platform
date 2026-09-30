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
