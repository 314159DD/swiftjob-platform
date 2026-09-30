# 4. Public platform repository, private product repositories

- Status: accepted
- Date: 2026-09-30

## Context

The platform repository is a portfolio piece and is meant to be read. The application it hosts is a commercial
product ([SwiftJob](https://swiftjob.de)), and how it works is not for competitors to read. GitHub Free has no
environments and no branch protection for private repositories, and both are central to the design (ADR 1).

## Decision

- Public: everything needed to understand and rebuild the landing zone. Terraform, scripts, workflows, tests,
  ADRs, the verification and migration logs. The repository states that SwiftJob exists, runs on Azure and has
  a web app, an API and scheduled jobs.
- Private: the three application repositories and everything about how the product works.
- A leak check (`scripts/leak-check.sh`, job `Leak check`) fails a pull request when a tracked file contains a
  blocked term. The list of terms is a repository secret, so the list itself is not public. The check
  prints file and line and never the term, because the Actions logs are public. Terms are matched literally.
  The tests in `tests/leak-check.test.sh` cover a clean repository, a hit reported by file and line, the output never containing the
  term, empty and missing blocklists, literal matching and the error path.
- The check first failed open. Git for Windows ships grep 3.0, which aborts on `-i` with several patterns, and the
  original `2>/dev/null || true` hid the abort. Grep errors now exit with code 2, terms are escaped and joined
  into one alternation, and the error path has a test.
- Terraform plans reach pull requests and logs only as a per-type summary from `scripts/plan_summary.py`:
  resource types and counts, no names and no values. A test asserts that names and values never appear.
- The repository was private while it was built and went public on 2026-09-29, after a check of all files and
  all commit messages against the blocklist (0 hits in each). It had to become public because environments and
  branch protection do not exist for private repositories on the Free plan.

## Consequences

- Anyone can read how the platform is built and check it against the verification log.
- The blocklist is maintained by hand. A leak that uses a term not on the list is not caught, which is why the
  documentation refers to the application only in general terms ("the web app", "the API", "the scheduled
  jobs").
- Commit messages and pull request texts are public and follow the same rule as the files.
