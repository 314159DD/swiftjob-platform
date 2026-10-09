# Runbook: restore the PostgreSQL database

Applies to the flexible server of `staging` and `prod` (ADR 9). Written before the first drill: numbers marked
"measured" are placeholders until `docs/verification.md` has a drill entry.

## When to restore

- Data loss: rows, a table or a database deleted or overwritten by a bug or by a person.
- A bad migration that cannot be fixed forward (the migrations are expand only, so this is rare; try a forward fix first).
- Corruption, or a server that cannot be repaired.

Do not restore for a failed deploy (roll the app back by digest) or for a slow query.

## What the platform gives us

| Item | Value | Source |
|---|---|---|
| Method | point-in-time restore (PITR) to a **new** server | Azure; an in-place restore does not exist for flexible servers |
| Retention (recovery window) | 7 days, `backup_retention_days = 7` | `modules/workload/postgres.tf` |
| RPO | transaction logs are archived continuously; Microsoft states a delay of up to about 5 minutes | Microsoft Learn, backup and restore |
| Backup redundancy | local or zone redundant per region; **geo-redundant backup is off** (`geo_redundant_backup_enabled = false`, ADR 9) | module |
| Regional disaster | not covered: no geo-restore without geo-redundant backup | module |
| High availability | off | ADR 9 |
| Compute of a restore | same tier and size as the source (B1ms), same storage and retention | Azure |
| RTO | **not measured yet** (placeholder: minutes up to an hour for 32 GB; the drill records the real number) | `docs/verification.md` |

A restore does not copy firewall rules or Entra administrators. Server parameters are not copied either. The
restored server therefore starts with no way in until an administrator and a firewall rule are added on it. The drill
script does exactly that for its own checks.

## Who runs it

The owner, signed in with `az` as the Entra administrator of the server (the break-glass principal of ADR 9), from a
machine with `psql` and with a public IPv4 address that may open a temporary firewall rule. The pipeline identities
cannot do this and must not be given the rights to.

## Drill (run it before it is needed)

```
bash scripts/pg-restore-drill.sh staging --expected-migration <highest version>
bash scripts/pg-restore-drill.sh prod    --expected-migration <highest version> --minutes-ago 15
```

- `<highest version>` is the newest file name in the backend's `db/migrations` without `.sql` (for example `0043_name`),
  or set `DRILL_COMPARE_SOURCE=1` to read it from the source (this opens a temporary firewall rule for your address on
  the SOURCE server and removes it again).
- It restores to a temporary server `psql-swiftjob-<env>-drill-<timestamp>`, adds the administrator and your address on
  that server only, signs in with an Entra token in a read-only session, counts `jobs`, `app_users` and `scan_run`,
  compares the highest `migrations.schema_migrations.version`, prints the timings, and deletes the server again.
- Exit 0 means all checks passed, 1 a check or step failed, 2 the temporary server could not be deleted (the message
  names it; delete it by hand, it bills).
- `--keep` leaves the server for a closer look. Delete it afterwards, the script prints the command.
- If row level security hides rows from the administrator, set `DRILL_SET_ROLE` to the owner role of the tables.
- Cost: a second B1ms server for the time of the drill (roughly 0.02 EUR per hour plus storage). The free grant of 750
  hours covers one always-on B1ms for the whole subscription, so a drill is billed. Run it, record the numbers, and let
  it delete. Never run it from CI.
- Record in `docs/verification.md`: date, environment, restore until Ready, restore until sign-in (this is the RTO of
  the drill), counts, pass or fail. Replace the RTO placeholder above with the measured value.

## Restore for real

1. Decide the restore point: the last moment before the damage (UTC). Anything written after it is lost on the new server.
2. Stop the damage first: if the cause is a running job or deploy, stop it (disable the job, hold the pipeline).
3. Restore to a new server with a name that is not the production name:
   `az postgres flexible-server restore -g <rg> --name <new> --source-server <source> --restore-time <UTC ISO 8601>`.
   Keep the damaged server until the new one is verified.
4. Add the Entra administrator and a temporary firewall rule on the new server (as the drill script does) and check the
   data with a read-only session.
5. Bring the application back on the good data. Pick one:
   - **Copy back (default).** Dump the good tables from the restored server and load them into the existing server
     (`pg_dump` and `pg_restore` or `COPY`), as a migration-style, reviewed operation. Names, identities, alerts and
     Terraform state stay as they are. Right for small damage in a few tables.
   - **Switch servers.** Point the applications at the new server: the host the apps receive comes from the Terraform
     resource of the server (`PGHOST` in `modules/workload/postgres.tf`), so this means importing the restored server into
     the state of the environment in place of the old one, or a temporary host override in the private configuration
     repository, then `apply`. Both are owner-gated applies; the role mapping (workload identities to roles) is part of
     the restored data, but the Entra administrators and the firewall rule `allow-azure-services` must be added to the new
     server first, and the alerts and tags re-created by Terraform. Rehearse this path on staging before relying on it.
6. Run `scripts/smoke-staging.sh` (staging) or the production smoke checks, then re-enable jobs.
7. Delete the damaged or the temporary server only after the owner confirms the data. A deleted server takes its backups with it.

## Notes

- PITR can only restore within the same region and with the same network mode (public to public).
- The restore time must be inside the retention window and after the server's first backup.
- If the restore is refused by the Entra-only policy (`RequestDisallowedByPolicy`), the request has to carry the
  authentication settings; use the REST API or the portal with Entra authentication enabled and password authentication
  disabled, and report it so the script can be adjusted.
- Locks: before real customer data, a `CanNotDelete` lock on the production server is planned (see the module comment).
  Keep the drill's temporary server outside any such lock.
