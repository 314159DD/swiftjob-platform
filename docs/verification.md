# Verification

What was checked against the live deployment, how to repeat each check, and the dated results with the run
that produced them. Run IDs link to GitHub Actions.

## Checks

| Check | Repeat it with |
|---|---|
| Bootstrap is idempotent and leaves no elevated access | Run `scripts/bootstrap.sh` again, compare its output values, then `MSYS_NO_PATHCONV=1 az role assignment list --scope / --role "User Access Administrator" --query "[?scope=='/']" -o table` must be empty (on Linux or macOS drop the prefix) |
| Apply is idempotent | The last step of the `Apply` workflow: a second plan must report no changes |
| Policies are compliant | Azure Policy compliance report for `mg-swiftjob`, or `az policy state summarize --management-group mg-swiftjob` |
| Forbidden resources are refused | Run the `Policy test` workflow (also weekly, Monday 05:17 UTC) |
| The policy test can fail | `bash scripts/policy-test.sh rg-swiftjob-platform` with a temporary `enforce_policies = false`: the forbidden templates validate and the test is red. The recorded evidence is run 36651056141 (red) and 36652775932 (green); the weekly workflow repeats the green case |
| Drift is detected | Change a platform resource by hand, run the `Drift` workflow (also nightly, 03:37 UTC): red. Revert it: green |
| The leak check works | `bash tests/leak-check.test.sh`, and the `Leak check` job on every pull request |
| The drift exit codes are mapped correctly | `bash tests/drift-exit.test.sh` |
| The plan summary shows no names or values | `python -m pytest tests -q` |
| `tf-plan` cannot write state | Run the `Rights test` workflow (also weekly), job `tf-plan`: an upload to the platform, staging and prod state containers is refused, a list succeeds |
| `tf-staging` cannot touch production or grant itself more | `Rights test`, job `tf-staging`: production and platform changes, a role outside the ABAC list, a self-grant of Key Vault Secrets User, a grant at subscription scope, a write to the platform and production state and an allowed role granted to a user (`RIGHTS_TEST_USER_ID`) are refused; the control grants an allowed role to another identity and removes it |
| Staging apply is idempotent | The last step of the `Apply staging` workflow: a second plan must report no changes |
| Phase 2 policies refuse what they should | `Policy test` workflow: the phase 2 templates that exist (Container Apps environment with a VNet subnet, Container Apps dedicated workload profile, Standard load balancer, private endpoint, PostgreSQL password auth, storage in a region outside the allowed list and in the compute region) are refused by the named policy. Controls that must pass: the allowed template, the Static Web App template and the Container Apps template in the compute region |
| The safety net for the application repositories exists | In each private application repository: `git tag -l pre-azure-2026-09-30`, `git branch --list azure-migration`, and `git bundle verify` on the offline bundle |

## 2026-09-29 to 2026-09-30: first apply and idempotency

- Bootstrap: 4 runs, all exit code 0, identical output values. The root management group `mg-swiftjob` was
  created without elevated access. Afterwards there were 0 "User Access Administrator" assignments at `/`.
- Apply [36647231734](https://github.com/314159DD/swiftjob-platform/actions/runs/36647231734): 24 resources
  created and the root management group imported (5 management groups, the Log Analytics workspace, the subscription budget,
  12 policy assignments, 1 policy definition, 4 role assignments). The second plan reported "no changes".
- After the owner moved the subscription under `mg-workloads`, Apply
  [36648633515](https://github.com/314159DD/swiftjob-platform/actions/runs/36648633515) reported no changes.

## 2026-09-30: compliance report before enforcement

- The existing resource groups were tagged first, merging with their existing tags: `rg-cloudresume`
  (`env=production`), `rg-cloudresume-staging` (`env=staging`), `rg-cloudresume-nettest`
  (`env=network-test`) and `NetworkWatcherRG` (`project=azure-shared`, `env=shared`, `owner=steven`). The other
  project's bootstrap now also sets `env` (a pull request in that repository).
- The scan at about 00:14 UTC showed 0 non-compliant resources for every evaluated assignment.
- PR #5 switched `enforce_policies` to `true`. Its plan showed 12 policy assignments to update and nothing else.
  Apply [36651226675](https://github.com/314159DD/swiftjob-platform/actions/runs/36651226675) succeeded and the
  second plan reported no changes.

## 2026-09-30: policy test, red before and green after enforcement

- Before enforcement, run [36651056141](https://github.com/314159DD/swiftjob-platform/actions/runs/36651056141):
  all four forbidden templates validated, which the test reports as a failure ("not refused"), and the control
  template validated. The test can go red.
- After enforcement and a 15 minute wait, run
  [36652775932](https://github.com/314159DD/swiftjob-platform/actions/runs/36652775932) succeeded:

  ```
  PASS: storage-shared-key refused by deny-storage-shared-key
  PASS: wrong-region refused by allowed-locations
  PASS: nat-gateway refused by deny-costly-types
  PASS: postgres-large refused by deny-costly-skus
  PASS: allowed-control validates
  ```

- The other project in the same subscription
  ([azure-cloud-resume](https://github.com/314159DD/azure-cloud-resume)) deployed under the enforced policies:
  Deploy run [36652938651](https://github.com/314159DD/azure-cloud-resume/actions/runs/36652938651), staging
  and production succeeded and both smoke tests passed.

## 2026-09-30: drift detection

- The Log Analytics workspace retention was changed by hand from 30 to 31 days. Run
  [36651866928](https://github.com/314159DD/swiftjob-platform/actions/runs/36651866928) failed with "drift:
  Azure differs from the code".
- The retention was set back to 30. Run
  [36651971228](https://github.com/314159DD/swiftjob-platform/actions/runs/36651971228) passed with "no drift".

## 2026-09-30: safety net for the application repositories

In each of the three private application repositories the tag `pre-azure-2026-09-30` and the branch
`azure-migration` exist. Offline bundles of the three repositories were written and verified by cloning them.

## 2026-09-30: phase 2a, hardened pipeline

- Task 1, plan output: Apply [36661126894](https://github.com/314159DD/swiftjob-platform/actions/runs/36661126894) after the merge of the output rules (`tf-layer.sh`, redaction): no changes.
- Task 2, `tf-plan` reads only. Bootstrap run 7 exit 0 with the same values. `tf-plan` holds Reader on the management
  group and the subscription and Storage Blob Data Reader on the three state containers; Storage Blob Data
  Contributor is gone. Drift [36662273886](https://github.com/314159DD/swiftjob-platform/actions/runs/36662273886) succeeded with lock-free plans and the guard passed. Rights test
  [36662520366](https://github.com/314159DD/swiftjob-platform/actions/runs/36662520366): 4 PASS for `tf-plan`. PR #12 planned the platform layer with the reader-only identity.
- Task 4, `tf-staging`. Bootstrap run 12 exit 0, 4 pipeline identities. Rights test [36665621981](https://github.com/314159DD/swiftjob-platform/actions/runs/36665621981): `tf-plan` 4 PASS,
  `tf-staging` 7 PASS (6 refusals and the control). Drift [36665623866](https://github.com/314159DD/swiftjob-platform/actions/runs/36665623866): guard passed with 4 IDs, no drift. Azure
  accepted `PrincipalId` and `PrincipalType` in the ABAC condition.
- Findings: the bootstrap failed twice while a new custom role was not yet readable (replication lag), so it now
  retries; updating a role needs both the resource `id` and `roleName` with `az` 2.90.

## 2026-09-30: phase 2 policies, compliance and policy tests

- Task 5, before enforcement. Policy test [36668175381](https://github.com/314159DD/swiftjob-platform/actions/runs/36668175381) was red as intended: the 3 old templates passed, the 6 new
  forbidden templates validated ("not refused") and the 2 controls passed. The private endpoint template validated
  without a resource provider preflight failure. The compliance report for all assignments showed 0 non-compliant
  resources.
- Task 6, enforcement. PR #21 removed `allowed-locations`, kept `allowed-rg-locations` unchanged (the resource groups of
  the other project live in `westeurope`, ADR 3) and set `enforce_phase2_policies = true`. Platform apply
  [36689799328](https://github.com/314159DD/swiftjob-platform/actions/runs/36689799328) succeeded.
- Task 6, after enforcement. Policy test [36691827570](https://github.com/314159DD/swiftjob-platform/actions/runs/36691827570): all 10 forbidden templates refused, the Container Apps
  control refused by the provider quota (one environment per trial subscription). After PR #23, [36693925274](https://github.com/314159DD/swiftjob-platform/actions/runs/36693925274): 13 of
  13 PASS. A1 under the enforced policies: guardrail verification [36691831989](https://github.com/314159DD/azure-cloud-resume/actions/runs/36691831989), private network
  test [36694018975](https://github.com/314159DD/azure-cloud-resume/actions/runs/36694018975).

## 2026-09-30: phase 2a, staging infrastructure

- Task 8, staging apply history:
  - [36668701517](https://github.com/314159DD/swiftjob-platform/actions/runs/36668701517): failed. The Container Apps environment could not be created in `germanywestcentral`
    (`ManagedEnvironmentCapacityHeavyUsageError`, Azure capacity). Everything else was created. The failed
    environment was deleted.
  - [36686786541](https://github.com/314159DD/swiftjob-platform/actions/runs/36686786541): failed in `westeurope`. Azure blocks new customers there with a platform policy (ADR 7,
    superseded by ADR 8).
  - [36688617466](https://github.com/314159DD/swiftjob-platform/actions/runs/36688617466): applied with the environment `cae-swiftjob-staging` in `swedencentral`, but the verify step found
    a second plan diff (a diagnostic setting attribute that reads back as null). PR #20 removed the attribute.
  - [36689428551](https://github.com/314159DD/swiftjob-platform/actions/runs/36689428551): green, including the second plan with no changes. This is the first fully idempotent staging
    apply.
- Task 8 follow-ups (PR #22): the apply pins a private commit quietly after an ancestry check, and a missing state
  fails when its resource group has resources. Dispatch [36690802149](https://github.com/314159DD/swiftjob-platform/actions/runs/36690802149) with a commit SHA was green and idempotent,
  and its log held 0 hits for the private commit subject (ADR 5).
- Cost check: nothing the staging layer created carries an hourly price (ADR 5).
- `Plan (staging)` with `tf-plan` after the staging state existed: CI run
  [36693775325](https://github.com/314159DD/swiftjob-platform/actions/runs/36693775325) (PR #23) was green with "No changes", so the custom
  `swiftjob-plan-reader` role needed no further action (ADR 5). The first nightly Drift with both legs is not yet recorded.

## 2026-10-01 to 2026-10-02: phase 3, database on Azure

Server facts (staging): `psql-swiftjob-staging-0708df`, Sweden Central (ADR 9), Standard_B1ms Burstable, PostgreSQL 17, 32 GB
storage with autogrow off, backup retention 7 days, geo-redundant backup off, high availability off. Password
sign-in is disabled and Entra sign-in enabled; two Entra administrators (the migration identity and the owner).
`require_secure_transport` is on, minimum TLS 1.2. The only firewall rule is `allow-azure-services`. It is the only
PostgreSQL server in the subscription.

Alerts: `alert-swiftjob-staging-pg-cpu`, `alert-swiftjob-staging-pg-storage`, `alert-swiftjob-staging-pg-connections`.
Budgets unchanged: subscription 25 EUR and staging 5 EUR, each at 50, 80 and 100 percent.

- Server apply: [36844822374](https://github.com/314159DD/swiftjob-platform/actions/runs/36844822374) green and idempotent (second plan "no changes").
- Access test: [36846067177](https://github.com/314159DD/swiftjob-platform/actions/runs/36846067177) 12 PASS, 1 FAIL (the foreign-identity refusal returned the same text as a
  wrong password). Fixed with a token control in the test (PR #32) and `REQUIRE_POSTGRES=1` (PR #33).
  [36847206200](https://github.com/314159DD/swiftjob-platform/actions/runs/36847206200) on main: **14/14 PASS with `REQUIRE_POSTGRES=1`**.
- First migration on Azure, 2026-10-01 18:43Z: execution `job-staging-db-migrate-b7edl6y` applied=12 principals=3; rerun
  `job-staging-db-migrate-08xza5h` applied=0 (idempotent). Config apply
  [36908646456](https://github.com/314159DD/swiftjob-platform/actions/runs/36908646456). A first attempt failed with `ImagePullUnauthorized` because the registry pull
  secret held 1 character; the owner stored the real token and the job ran.
- Real workload on staging, 2026-10-02: config PR #19, apply [37010659140](https://github.com/314159DD/swiftjob-platform/actions/runs/37010659140) (attempt 1 failed in
  Apply after 27 s with the error text withheld, attempt 2 via `gh run rerun --failed` green, second plan no
  changes). Smoke 6/6 PASS. Migration rerun on the new image: applied=0 principals=3.
- RLS check as a job: `job-staging-db-rls-check-5xdgsvs` Succeeded, `RLS_CHECK tables=31 isolated=31 failed=0`
  (local run of the same probe earlier: also all isolated).
- Product flows on staging against the Azure database, checked through the API with throwaway users created by an
  administrator (sign-up is disabled on the staging login server; the browser UI and its network traffic were not
  inspected). All PASS: sign-in token (ES256) and profile creation on first call, profile read and write, document upload and byte-identical download from object storage, settings, onboarding
  completion, job listing, GDPR export, refresh-token grant, account deletion (200, then sign-in refused, old token
  refused). Tombstone: right after deletion workers without the cached mapping answered 401 "Account deleted", after
  615 s all 6 of 6 did (cache TTL 600 s, by design).
- Payment provider, test mode only, end to end: checkout session 200, subscription updated moved the plan to pro,
  subscription deleted moved it to free; webhook delivered, 0 pending.
- Break-glass: the owner (Entra administrator) signed in to the staging database on 2026-10-02 through a temporary
  firewall rule, which was removed afterwards (only `allow-azure-services` remains).
- Platform apply [37017816376](https://github.com/314159DD/swiftjob-platform/actions/runs/37017816376) (PR #35, error summary for withheld apply failures) and staging apply
  [37017816402](https://github.com/314159DD/swiftjob-platform/actions/runs/37017816402) green.
- Peak connections: 12 (metric Maximum per 5 minutes, 2026-10-02 13:00 to 13:40Z) against a budget of 30 user
  connections.
- Token refresh: only the refresh-token grant was proven (a new token was accepted by the API). The check with a
  short token lifetime was not done.
- Cost of the PostgreSQL server: **pending**. Usage data lags 24 to 72 hours. Check on 2026-10-02 and again on
  2026-10-04; expected 0 EUR with the free grant, otherwise about 0.53 EUR per day. If it is not zero, the owner
  decides between stopping the server when no test runs and raising the staging budget to 20 EUR.
- Deferred, owner-gated: the production data export (03a Task 1) and the import run (03d Task 4); the code for both
  is merged.
- **Not yet done** (03d Task 5): step 3 sign-up through the UI with a check of the browser network traffic; step 4
  aggregator and evaluation runs against the Azure database (a dry-run aggregation, a health report, one evaluation
  queue run, connections under that load; no model or source calls were run, by owner decision), so the aggregator image
  has never run against it; step 5 token refresh with a short lifetime. Step 7 owner confirmation on the old
  dashboard is also open. Peak connections above were measured under the product flows only.

## 2026-10-02: phase 3 follow-ups on staging

- Configuration PRs #24 and #25 (private repository) combined the image bumps and enabled four database-only jobs
  (daily credit reset, purge of old tombstones, purge of expired anonymous results, retry of failed login deletions)
  on the evaluate identity; every job that calls a model or an external source stays disabled. A read-only local plan
  showed 10 to add, 16 to change in place and 1 to replace, with no new resource type.
- Apply [37024661729](https://github.com/314159DD/swiftjob-platform/actions/runs/37024661729) green and idempotent (the first attempt, 37024470506, failed in Apply with the
  error text withheld, the second run completed it).
- Migration `job-staging-db-migrate-hklri7w`: applied=1 principals=3 (0019 grants); rerun `job-staging-db-migrate-2ng2pds`:
  applied=0.
- Each new job was started once, `JOB_RESULT status=ok`: credit-reset `users_reset=0`, purge-identities `purged=0`,
  purge-ats-results `purged=0`, retry-auth-deletes `pending=0 cleared=0`.
- Smoke: health check 200; the retired batch evaluation route answers 405 (no route).

## Findings during the build

- ARM `az deployment group validate` needs write permission for every resource type in the template, like
  `what-if`. The first CI run of the policy test
  ([36649469049](https://github.com/314159DD/swiftjob-platform/actions/runs/36649469049)) failed with
  "Authorization failed for template resource ... of type ..." for every template. The fix is the dedicated
  `swiftjob-policy-test` identity (ADR 1).
- The leak check failed open at first, see ADR 4.
- The Checkov action, pinned from the latest GitHub release, ran Checkov 2.0.930 with SARIF output and no
  visible result. It was replaced with `pip install checkov==3.3.20`. Checkov has no checks for the resource
  types in `platform/` (management groups, policy, budget, Log Analytics workspace). This was verified by adding
  an insecure storage account to a temporary copy, for which Checkov exited with 1.
- tflint ignored the repository config when run with `--chdir`. It is now run with `--config`.
- GitHub Free has no environments or branch protection in private repositories. The repository was made
  public early, after a check that it contained no product internals, and configured then.

## 2026-09-30: final review finding

Azure gives the creator of a new management group Owner on it. Terraform, running as `swiftjob-tf-platform`,
created `mg-platform`, `mg-workloads`, `mg-prod`, `mg-nonprod` and `mg-sandbox`, so the Azure Management Groups
service principal assigned that identity Owner on each of the five. Terraform does not track these assignments,
so the drift check could not see them. The owner removed all five assignments.

The fix: `scripts/bootstrap.sh` removes Owner and User Access Administrator assignments from the three pipeline
identities at every management group under `mg-swiftjob`. The nightly Drift workflow runs `scripts/rbac-guard.sh`
first and fails when a pipeline identity holds Owner, User Access Administrator, or an unconditioned Role Based
Access Control Administrator. Guard added in this change; first run recorded later.
