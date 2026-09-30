# 1. Terraform with layered state and separate identities

- Status: accepted
- Date: 2026-09-30

## Context

The platform needs management groups, policy, a budget and later the environments themselves. It is built from
a public repository and applied by GitHub Actions. Two questions decide the tooling: which infrastructure
language, and which identities may do what.

The other project in the same subscription ([azure-cloud-resume](https://github.com/314159DD/azure-cloud-resume))
uses Bicep. That worked for a single resource group. For a platform that spans management groups and several
environments, Terraform is the more widely used tool in the market, keeps an explicit state file and has a
`plan` that only needs read access. ARM's `what-if` and `az deployment ... validate` need write permission on
every resource type in the template. This was confirmed in practice: the first CI run of the policy test
([36649469049](https://github.com/314159DD/swiftjob-platform/actions/runs/36649469049)) failed with
"Authorization failed for template resource ... of type ..." for every template, using an identity that could
only read.

## Decision

- Terraform, version `~> 1.16`, with the azurerm provider `~> 5.7`. Provider registration is switched off in
  the provider block; the bootstrap script registers the providers once.
- State lives in the storage account `stswiftjobtf3100a5` in `rg-swiftjob-tfstate`. Shared key access and public
  blob access are off, TLS 1.2 is the minimum, blob versioning is on and soft delete keeps 30 days. Terraform
  authenticates with Entra ID only, so there is no storage key anywhere. There is one container per layer:
  `platform`, `staging` and `prod`.
- Three identities, all GitHub OIDC federated with no secret. The subject contains the immutable owner and
  repository IDs and names one GitHub environment, so a repository recreated under the same name would not
  inherit the trust.
  - `swiftjob-tf-plan` (environment `plan`): Reader on `mg-swiftjob` and on the subscription, plus Storage Blob
    Data Contributor on the three state containers only (the state lock needs write). It is read-only on
    Azure resources but has write on the state containers (for the state lock), so it is not "plan and nothing
    else". It will be reduced to read plus lock-free plans in the next phase.
  - `swiftjob-tf-platform` (environment `platform`, required reviewer, `main` only): Reader, Management Group
    Contributor and Resource Policy Contributor on `mg-swiftjob`; Contributor on `rg-swiftjob-platform`; Cost
    Management Contributor on the subscription; Storage Blob Data Contributor on the `platform` container. It
    also holds Role Based Access Control Administrator on `mg-swiftjob` with an ABAC condition that only allows
    granting and removing Log Analytics Contributor and Monitoring Contributor, which the diagnostics policies
    need for their managed identities.
  - `swiftjob-policy-test` (environment `policy-test`, `main` only, no reviewer): a custom role on
    `rg-swiftjob-platform` with write on exactly the resource types the policy test validates (see ADR 3).
- Some steps stay imperative and run once from the owner's machine: `scripts/bootstrap.sh` (state storage, the
  root management group, the identities, provider registration), `scripts/configure-github.sh` (environments and
  branch protection) and `scripts/move-subscription.sh` (moving the subscription under `mg-workloads`). They
  create what Terraform itself needs in order to run, or they are rare privileged acts that no pipeline should
  hold permission for. The bootstrap is idempotent: it ran four times with identical output. It has no
  fallback to elevated tenant access, because that could leave User Access Administrator at `/` behind. A
  check after the last run found 0 such assignments.

## Consequences

- A pull request gets `plan` through an identity that cannot change anything. Merging triggers an apply that a
  reviewer has to approve, and the apply job runs a second plan that must report no changes.
- Terraform output stays out of the public log. The apply job sends plan and apply output to `/dev/null` and
  writes only the per-type summary from `scripts/plan_summary.py` to the job summary.
- Adding an environment layer means adding its identity in the bootstrap (the staging and prod state
  containers already exist).
- The three identities and the state account are not managed by Terraform. Changing them means editing the
  bootstrap script and running it again.
