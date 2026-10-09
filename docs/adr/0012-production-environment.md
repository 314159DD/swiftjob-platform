# 12. The production environment: a second workload layer with its own identity

- Status: proposed (written ahead of the PAYG switch; the owner confirms the open choices below)
- Date: 2026-10-09

## Context

Staging proves the workload module (ADR 5). Production needs the same shape with stronger protection: a different
pipeline identity that cannot touch staging, a human approval before every change, protection against deleting data
resources, custom domains with certificates, and an update path that migrates the database before the apps change.
Only one Container Apps environment fits the trial subscription, so none of this can be applied before the
pay-as-you-go switch. This ADR and the code behind it are written first so the first production apply is a review,
not a design session.

## Decision

- **A second root, `environments/prod`, over the same module.** Its own state key (`prod.tfstate` in the existing
  `prod` container), its own resource group `rg-swiftjob-prod`, values from the `prod/` folder of the private
  configuration repository. The module is not forked; production differences are variables.
- **Its own pipeline identity, `swiftjob-tf-prod`,** bound to the GitHub environment `production` and to nothing else.
  Roles mirror `swiftjob-tf-staging` but only on the production resource group and the `prod` state container, with
  the same ABAC list for role assignments (service principals only, never itself). The weekly rights test gets a
  `tf-prod` leg (manual, see below). The residual risk of Log Analytics Contributor on the central workspace is the
  same as for staging (ADR 5).
- **A required reviewer on `production` and a dispatch-only workflow.** `apply-prod.yml` has no push, schedule or pull
  request trigger. A merge to `main` therefore cannot change production; a person dispatches the run and a second
  approval releases the job. `tests/workflow-triggers.test.sh` pins this.
- **Promotion by digest.** The API, migration and aggregator images that ran on staging are copied by digest into the
  production configuration. Only the web image is rebuilt, because the frontend inlines public URLs at build time.
- **Migration before deploy.** `apply-prod.yml` plans, runs `scripts/db-migrate.sh prod` (targeted apply of the
  `db-migrate` job, start, wait for the execution), plans again and applies. Migrations are expand-only; a contract
  migration ships one release after the code stopped reading the old shape.
- **Delete guard.** `scripts/prod-guard.py` reads the plan JSON and fails the run before apply when it deletes or
  replaces the PostgreSQL server, the storage account or the Key Vault (a replace is a delete plus a create). It runs on
  the first plan and on the plan that is applied, and prints only the resource type. `prevent_destroy` is not used: it
  must be a literal in the module, which would also protect staging and throwaway environments from removal. Instead
  the owner sets `CanNotDelete` locks on the server and the storage account (a Contributor cannot write locks, so the
  pipeline cannot remove them either), and Terraform enables Key Vault purge protection through
  `key_vault_purge_protection` (default true in production, false elsewhere; irreversible on that vault).
- **Custom domains with managed certificates, behind a flag.** The module declares `apps.*.custom_domains` and creates
  an `azurerm_container_app_custom_domain` per host name when `enable_custom_domains` is true. Omitting the
  certificate id asks Azure for a managed certificate; Azure binds it afterwards, so `certificate_binding_type` and
  `container_app_environment_certificate_id` are in `ignore_changes`. A managed certificate is validated over HTTP
  (apex, A record to the environment's static IP) or CNAME (subdomains, CNAME to the app host name) and needs the
  `asuid` TXT record, so it can only be issued after the DNS records point at Azure. The first apply therefore runs
  with the flag off, and a second apply turns it on once DNS is in place. Consequence: there is a gap between the
  DNS change and the certificate; the cutover runbook measures it and keeps the old site frozen until both names
  are secured. If the provider cannot complete the managed-certificate flow in practice, the fallback is
  `az containerapp hostname bind` for the certificate with the hostname declared in Terraform; this is not verified
  before the first real run.
- **Warm replicas.** `min_replicas = 1` for the API and the web app removes the measured cold start of 20 to 54
  seconds, at about 20 to 30 EUR per month. One API replica at launch keeps the PostgreSQL connection budget of the
  B1ms server (35 user connections) intact.
- **Region.** Compute and PostgreSQL in Sweden Central as on staging, so every measured number carries over (ADR 8,
  ADR 9). Moving both to Germany West Central later is a configuration change plus a data move.
- **Open owner choices are variables with the recommended default,** marked `owner decision pending` in
  `environments/prod/variables.tf`: warm replicas (Q5), PostgreSQL SKU (Q4, the type default of `postgres.sku_name`), resource group budget (Q6). The
  subscription safety net (platform layer, now 25 EUR) is raised to 75 EUR in a separate platform change once Q6 is
  answered; it is not part of this change because it would alter the live budget before the switch.

## Consequences

- The production plan job in CI is inert until the repository variable `PROD_READY` is `true`. Before the identity,
  the state and the private `prod/` folder exist there is nothing to plan.
- Merging changes to `modules/**` or `scripts/tf-*.sh` still deploys staging (and applies the platform layer); the
  expected plan for the production-enabling change is "no changes" because nothing in staging sets the new inputs.
- `PIPELINE_PRINCIPAL_IDS` grows from four to five ids; the drift guard accepts both until the bootstrap is re-run.
- Staging and production share the free PostgreSQL grant (750 hours a month for the subscription). Two always-on
  B1ms servers cost about 12.50 EUR a month beyond the grant (Q3). `scripts/staging-postgres.sh` stops and starts the
  staging server by hand; there is no automated schedule, because the pipeline identities cannot be given a scheduler
  without widening their rights.
