# 5. The workload layer, private configuration and the staging pipeline identity

- Status: accepted
- Date: 2026-09-30

## Context

Phase 2 adds workload infrastructure: a Container Apps environment, a Key Vault, a storage account, monitoring and a
cost kill switch for each environment. Two questions follow. How is the product-specific part of that
infrastructure kept out of a public repository, and which identity applies it without being able to make itself
more powerful (ADR 1)?

## Decision

### Structure

- One module, `modules/workload/`, holds everything a workload environment consists of. Each environment is a root
  in `environments/<env>/` with its own state container and its own pipeline identity. Production later reuses the
  module with its own root, state and identity.
- Names, container names, app settings, secret names, schedules, scale values and image digests are product
  configuration. They live in the private repository `314159DD/swiftjob-platform-config`, as the `terraform.tfvars`
  of each environment. The public repository holds only the code that consumes them and neutral test data.
  ADR 4 explains why the line runs there.
- The public workflows read the private repository with a read-only deploy key (secret
  `CONFIG_REPO_DEPLOY_KEY`). The key cannot write.
- Changes to configuration go through the private repository: a bump branch, a pull request, a merge to main, and
  then a dispatch. The dispatch uses a fine-grained token (`PLATFORM_DISPATCH_TOKEN`) that can only start workflows
  in the public repository. The token has an expiry date, and an expired token stops the dispatch and nothing else.
  The expiry date is recorded where the token is created (open item at the time of writing).
- GitHub Free has no branch protection and no environments in a private repository. The `Diagnose` workflow of the
  private repository therefore federates by branch (main) instead of by environment.

### Output rules

- Every Terraform command in a workflow runs through `scripts/tf-layer.sh`. For the platform layer, standard error
  is printed after redaction (`scripts/redact.sh`). For a layer with private inputs (`staging`, later `prod`),
  standard error is suppressed: the log shows only "failed with exit code N". An invalid value, a precondition
  message or a resource address can never reach a public log through Terraform's error text.
- Pull requests show plans only as the per-type summary of `scripts/plan_summary.py`.
- The full text of a plan or an error is available only in the `Diagnose` workflow of the private repository.

### Trust model of the staging pipeline

- Only commits that are already on the main branch of the private repository can be deployed. The apply workflow
  checks out the private repository at `main` with full history. For a dispatch with a specific commit it checks
  that the commit is an ancestor of `main` (`git merge-base --is-ancestor`) and then pins it quietly, with all
  output discarded. A plain checkout by SHA would print the commit subject to the public log, and a private commit
  subject must not reach it. Dispatch run
  [36690802149](https://github.com/314159DD/swiftjob-platform/actions/runs/36690802149) with a SHA (PR #22) was
  green, idempotent and had 0 hits for the private commit subject in its log.
- A missing staging state is only skipped while its resource group is empty (`scripts/state-check.sh`). A missing
  state next to existing resources fails the run, so a deleted state cannot hide behind the skip.

### Roles of `swiftjob-tf-staging`

Federated from the GitHub environments `staging` and `nettest`, main branch only.

- Contributor on `rg-swiftjob-staging` and `rg-swiftjob-nettest`.
- Storage Blob Data Contributor on the `staging` state container only.
- Log Analytics Contributor on the central workspace only. Diagnostic settings, workspace-based Application Insights
  and log alert rules need it.
- Role Based Access Control Administrator on the two resource groups, with an ABAC condition. It may create role
  assignments only for these roles: Key Vault Secrets User, Storage Blob Data Contributor, Storage Blob Data Reader,
  Monitoring Metrics Publisher and `swiftjob-containerapp-stopper`. Only for principals of type `ServicePrincipal`
  (the condition checks the principal type), and never for its own principal ID. It may delete assignments of the
  same roles for service principals only. Azure accepted `PrincipalId` and `PrincipalType` in the condition when
  the bootstrap applied it.

### Roles of `tf-plan` for the workload layers

`tf-plan` gets the custom role `swiftjob-plan-reader` on the staging and production resource groups. It adds the
refresh-only actions that Reader lacks and that `terraform plan` calls while refreshing:

- `Microsoft.App/containerApps/listSecrets/action`
- `Microsoft.App/jobs/listSecrets/action`
- `Microsoft.Logic/workflows/triggers/listCallbackUrl/action` (the kill switch trigger URL)

No further action was needed when the staging plan was wired into the pipelines (Task 8). If a new action shows up,
it is added in the bootstrap and recorded here.

The weekly rights test proves the refusals: production and platform changes, a role outside the list, a self-grant
of Key Vault Secrets User, a grant at subscription scope, a write to the platform state. Its control grants an
allowed role to a different identity and removes it again.

### The kill switch

Budget at 100 % actual spend calls an action group, which posts to a Logic App with its own managed identity. The
Logic App lists the container apps of its resource group and stops each one. Its only role is the custom role
`swiftjob-containerapp-stopper` (read, stop, start on container apps) on that resource group. Databases and jobs
keep running. The trigger URL of the Logic App is a credential that can do exactly one thing, start the kill
switch, and Terraform stores it in the state. The state container has no shared key access and is readable only by
the pipeline identities, so this is accepted. The kill switch has not yet been fired end to end; that test is part
of plan 02c.

### Cost numbers behind the module

Azure Retail Prices API, EUR, checked before anything was created. Container Apps Standard vCPU and memory usage is
priced per second and rounds to 0.0000 within the free grants. Standard requests cost 0.3435 per million. The
Environment Management Hour (0.1116 per hour) and the Dedicated Plan Management Hour (0.0859 per hour) apply only
to VNet or dedicated profiles, which the module does not use and policy denies (ADR 6). Logic Apps Consumption
built-in actions cost 0.0, a standard connector action 0.0001 and an enterprise connector action 0.0009. Key Vault
operations cost 0.0258 per 10,000. Log Analytics data retention costs 0.103 per GB and month. Nothing the module
creates carries an hourly price. The central workspace keeps its 0.1 GB daily cap instead of a cap per environment.

## Consequences

- Residual risk: Contributor on the staging resource group lets `tf-staging` deploy a workload whose identity holds
  Key Vault Secrets User, and so read the staging vault indirectly. The ABAC condition blocks the direct self-grant
  only. Changes to the staging layer therefore stay behind a merge to main in the private repository.
- Residual risk: Log Analytics Contributor on the central workspace lets staging read all central logs, production
  included once it exists, and change the daily cap, retention or delete the workspace. The nightly platform drift
  shows a changed cap. To revisit with a narrower custom role before plan 05.
- `swiftjob-plan-reader` lets `tf-plan` list container app secrets. The workload modules must use Key Vault
  references only, so no secret value is ever stored in a container app definition.
- Storage account keys still land in the Terraform state, because the azurerm provider reads them (ListKeys) when it
  refreshes the account. They are unusable while shared key access is off, which policy enforces (ADR 3), and the
  state is private.
- Application Insights creates a smart-detector alert rule and an action group outside Terraform. They carry no
  tags, so the tag rules of the workload do not cover them. They are left alone and named here so a review does not
  mistake them for strays.
- The policy `diag-keyvault` (DeployIfNotExists) sends Key Vault audit logs to the central workspace. Those logs
  count toward the daily cap of 0.1 GB, so a busy vault can use up the cap for every other source.
- The staging pipeline depends on a private repository whose Actions can be blocked (billing) and a token that
  expires. Both fail closed: nothing is applied without them.
- The bootstrap must keep the ABAC condition and the rights test in step. If Azure rejects an attribute in the
  condition, the finding is recorded here.
- PostgreSQL in plan 03 must always send an authentication configuration on create and restore, because the
  Entra-only policy fails closed (ADR 3).
