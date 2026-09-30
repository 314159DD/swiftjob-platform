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
