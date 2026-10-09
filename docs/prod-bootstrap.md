# Production bootstrap: what the owner does after the PAYG switch

Order matters. Each owner step is followed by the commands the controller (the person or agent running the
pipeline) runs afterwards. No step here creates anything before the pay-as-you-go switch, and no value below is a
secret. Concepts and reasons are in [ADR 12](adr/0012-production-environment.md); the plan behind it is plan 05 of the
private migration plan set.

Names: layer `prod` (`environments/prod`), identity layer `identity-prod`, resource group `rg-swiftjob-prod`, state
container `prod`, pipeline identity `swiftjob-tf-prod`, GitHub environment `production`.

## 0. Decisions (owner, once)

Recorded with the date in the migration ledger. Defaults are in `environments/prod/variables.tf` and marked
`owner decision pending (plan 05 Qn)`.

| Question | Variable | Default |
|---|---|---|
| Q3 staging PostgreSQL after production takes the free grant | none (manual: `scripts/staging-postgres.sh stop`) | stop outside test days |
| Q4 PostgreSQL SKU | `postgres.sku_name` in the private configuration | `B_Standard_B1ms` (type default) |
| Q5 warm replicas for api and web | `min_replicas_api`, `min_replicas_web` | 1 and 1 |
| Q6 production budget | `budget_amount` | 50 EUR, kill switch at 100 % actual |
| Q6 subscription safety net (platform layer, `budget_amount` there) | not changed by this code | 25 now, 75 by a separate platform change |

## 1. Pay-as-you-go (owner)

1. Azure portal, Subscriptions, select the subscription, then **Upgrade** (banner at the top) or Cost Management +
   Billing, Subscriptions, **Upgrade subscription**. Choose pay-as-you-go. The subscription id does not change.
2. Wait until the portal shows the new offer.

Controller afterwards (read only):

```bash
export PATH="$PATH:/c/Program Files/Microsoft SDKs/Azure/CLI2/wbin" MSYS_NO_PATHCONV=1
az account show --query "{offer:subscriptionPolicies.quotaId, limit:subscriptionPolicies.spendingLimit}" -o json
az containerapp env list --query "[].name" -o tsv
```

Expected: offer is no longer the free trial, spending limit `Off`, one environment (staging).

## 2. Merge the code (controller, after review)

Merge the stacked platform pull request (after #51) and the configuration pull request. The merge deploys staging and
applies the platform layer only if their paths changed, and both plans must say "no changes". It never touches
production: `apply-prod.yml` and `identity-prod.yml` are dispatch-only (`bash tests/workflow-triggers.test.sh`).

## 3. Extended bootstrap (owner, Global Administrator)

Creates the app `swiftjob-tf-prod`, its federated credential for `environment:production`, and its roles on
`rg-swiftjob-prod` and the `prod` state container. Idempotent for everything that exists.

```bash
export PATH="$PATH:/c/Program Files/Microsoft SDKs/Azure/CLI2/wbin"
az login
GH_TOKEN=$(gh auth token --user 314159DD) bash scripts/bootstrap.sh | tee /tmp/bootstrap.out
GH_TOKEN=$(gh auth token --user 314159DD) bash scripts/configure-github.sh /tmp/bootstrap.out
```

`configure-github.sh` creates the GitHub environment `production` with the owner as **required reviewer**, `main`
only, and the variable `AZURE_CLIENT_ID` on it, and updates `PIPELINE_PRINCIPAL_IDS` to five ids. If GitHub refuses the
reviewer, set it by hand: repository Settings, Environments, production, Required reviewers, add yourself, tick
"Prevent self-review" off (a single-owner repository), Deployment branches: main.

Add the production tenant id, tenant sub-domain and the production resource names to the leak blocklist
(`gh secret set LEAK_BLOCKLIST` for Actions and for Dependabot) before any of them appears in a commit.

Controller afterwards:

```bash
gh variable set PROD_READY -R 314159DD/swiftjob-platform --body true
gh workflow run "Rights test" -R 314159DD/swiftjob-platform     # the tf-prod job runs on a manual dispatch only
gh run list -R 314159DD/swiftjob-platform --workflow "Rights test" -L 1
```

Expected: the `tf-prod` job is green after the owner approves the `production` environment. `PROD_READY` also makes
the pull request job `Plan (prod)` run; until the first apply it reports "first apply pending" and plans nothing.

## 4. Production tenant and `identity-prod` (owner, then controller)

Owner: create the production external tenant and the two Terraform identities in it, as for staging (plan 04 Task 2):
Entra admin center, Entra External ID, create an external tenant, name `SwiftJob`, country Germany; then the apps
`tf-identity-plan` (read) and `tf-identity-prod` (write) with federated credentials for the environments `plan` and
`production`. Record tenant id and client ids in the private configuration, never here.

Controller, after the owner has put the tenant ids into `prod/identity.auto.tfvars` (private repository, merged):

```bash
gh workflow run identity-prod.yml -R 314159DD/swiftjob-platform -f config_ref=<config commit sha>
```

The owner approves the `production` environment for the apply job. `extra_base_urls` in that file may name the
default host name of the web app for the rehearsal before DNS moves; remove it after the cutover.

## 5. First production apply, apps off (controller, owner approves)

The private `prod/terraform.tfvars` ships with `apps_enabled = false` and `enable_custom_domains` unset (false).

```bash
gh workflow run apply-prod.yml -R 314159DD/swiftjob-platform -f config_ref=<config commit sha>
```

The owner opens the run in GitHub (Actions, the run, **Review deployments**), ticks `production`, **Approve and
deploy**. Expected: environment, Key Vault with purge protection, storage, PostgreSQL, alerts, budget and kill switch;
second plan "no changes"; the delete guard prints "no guarded data resource is deleted or replaced". The step
"Migrate the database" defers because the job does not exist yet.

Then, controller, read only: server facts (`az postgres flexible-server show`, expect `swedencentral`,
`Standard_B1ms`, version 17, password auth disabled).

## 6. Locks and secrets (owner)

Locks (the pipeline cannot write or remove them; Contributor excludes `Microsoft.Authorization/locks`):

```bash
az lock create --name keep-postgres --lock-type CanNotDelete -g rg-swiftjob-prod \
  --resource-name <server name> --resource-type Microsoft.DBforPostgreSQL/flexibleServers
az lock create --name keep-storage --lock-type CanNotDelete -g rg-swiftjob-prod \
  --resource-name <storage account name> --resource-type Microsoft.Storage/storageAccounts
```

Secrets, typed at the prompt, nothing echoed (private configuration repository):

```bash
bash scripts/load-secrets.sh prod <prod vault>
az keyvault secret list --vault-name <prod vault> --query "[].name" -o tsv     # names only
```

A `CanNotDelete` lock also blocks `terraform destroy` of those resources, which is the intent.

## 7. Apps on, migration first (controller, owner approves)

Production images are never copied by hand and never built by a push. Two pull requests in the private configuration
repository fill `prod/images.auto.tfvars.json`; both are gated on the onboarding probe, and merging either deploys
nothing.

Owner inputs first (names only, values are public URLs):

| Where | Name | Value |
|---|---|---|
| frontend repository variable | `PROD_API_URL` | `https://api.swiftjob.de` |
| frontend repository variable | `PROD_WEB_URL` | `https://swiftjob.de` |

The Entra tenant and client ids are not build arguments: they are runtime settings from `prod/terraform.tfvars`.

1. **Staging is proven.** The staging release is merged and `Apply staging` succeeded. The controller runs the
   onboarding probe against staging for that commit (`PROBE=1`, `scripts/onboarding-probe.mjs` in the frontend repository; it
   writes a local JSON report only, so the proof is the checkbox below).
2. **Backend images (api, db, aggregator).** In the configuration repository, with the staging config commit that is on
   `main` and is what staging runs now:

   ```bash
   python scripts/promote.py --config-commit <sha> --push --verify-az
   ```

   `--verify-az` compares the api container app on staging with the digest (needs `az login`; leave it out to rely on
   main). The script refuses a commit that is not on main, digests staging main no longer holds, `db` different from
   `api`, and `web`. Pushing `promote/<12 hex>` makes `promote-pr.yml` open the pull request.
3. **Web image.** Dispatch the production build for the frontend commit staging proved:

   ```bash
   gh workflow run image-prod.yml -R <frontend repository> --ref azure-migration -f commit_sha=<40 hex>
   ```

   It builds with `PROD_API_URL` and `PROD_WEB_URL`, entra, no Supabase, no legacy link, pushes
   `swiftjob-web:prod-<sha>` and pushes `promote/web-<12 hex>` to the configuration repository.
4. **Gate.** In each promote pull request tick `Onboarding probe passed against staging for this commit (<12 hex>)`.
   The check `Promote gate` fails while it is unticked or names another commit; ticking it runs the check. Merge.
   The check is advisory: the private configuration repository is on a plan without branch protection, so it cannot be a
   required check (GitHub Pro would allow that; it is the owner's optional call). The gate is enforced when production
   is applied: `apply-prod.yml` runs `check-prod-config.py --strict` and `scripts/prod-provenance.sh` (api, db and
   aggregator digests must appear in the staging image history on main, the web digest must not) before any plan.
5. In the private configuration set `apps_enabled = true` (first apply only), merge, then:

```bash
gh workflow run apply-prod.yml -R 314159DD/swiftjob-platform -f config_ref=<config commit sha>
```

Expected in the log: `db-migrate` execution succeeded before the apps change, delete guard green twice, apply, second
plan empty, state secret check clean, smoke test green against the default host names.

## 8. DNS records at your DNS provider (owner), then custom domains (controller)

Controller reads the values (identifiers, not credentials):

```bash
az containerapp env show -g rg-swiftjob-prod -n cae-swiftjob-prod --query "{ip:properties.staticIp, verification:properties.customDomainConfiguration.customDomainVerificationId}" -o json
az containerapp show -g rg-swiftjob-prod -n ca-swiftjob-prod-web --query properties.configuration.ingress.fqdn -o tsv
az containerapp show -g rg-swiftjob-prod -n ca-swiftjob-prod-api --query properties.configuration.ingress.fqdn -o tsv
```

Owner, in the DNS zone of swiftjob.de at your DNS provider. Before the cutover only add the three TXT
records (they change nothing live):

| Type | Name | Value |
|---|---|---|
| TXT | `asuid` | verification id |
| TXT | `asuid.www` | verification id |
| TXT | `asuid.api` | verification id |

If a CAA record exists on the root it must allow `digicert.com`. Lower the TTL of the live records to 300 seconds (or
the provider's minimum) a day before the cutover. The cutover itself is the change of the live records, in one window:

| Type | Name | Value |
|---|---|---|
| A | `@` | environment static IP (replaces the current A record) |
| CNAME | `www` | web app host name (replaces the current record) |
| CNAME | `api` | api app host name (replaces the current record) |

Controller, once the records resolve to Azure (check with `nslookup`), turns the domains on: set
`enable_custom_domains = true` in the private `prod/terraform.tfvars`, merge, dispatch `apply-prod.yml` again, owner
approves. Then check that both names show a secured certificate:

```bash
az containerapp hostname list -g rg-swiftjob-prod -n ca-swiftjob-prod-web -o table
az containerapp hostname list -g rg-swiftjob-prod -n ca-swiftjob-prod-api -o table
```

Rollback is the DNS records put back to their old values (the old stack keeps running untouched).

Every later release repeats steps 1 to 4 and then dispatches `apply-prod.yml` with the merge commit as `config_ref`;
the migration runs first whenever the `db` digest changed.

## 9. After the cutover

Remove `extra_base_urls`, set the branch protection to require `Plan (prod)` (`configure-github.sh` lists the required
checks), and keep running `scripts/rights-test.sh prod` by manual dispatch after any role change.
