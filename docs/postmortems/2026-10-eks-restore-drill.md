# Post-mortem: first EKS restore drill

**Date:** 2026-10-31, 14:58 to 19:06 UTC
**Duration:** About 4 hours 8 minutes, including teardown
**Impact:** None on production. This was a planned drill, and it cost about $1.20 (estimated from the hourly rate, not yet billed).

## Summary

Forgejo and Kaneo were restored from the S3 backup into a temporary EKS cluster, using an automated nightly snapshot and no data from the home cluster. The restore passed: all 77 repositories came back, every one passed `git fsck`, and Kaneo matched its baseline exactly. Forgejo was ready 1 hour 19 minutes after the clock started. Two defects in the drill made the run longer than it should have been. Restic reported failure after restoring everything, and a bug in the script hung for about 2.5 hours, so Kaneo didn't finish until 3 hours 54 minutes.

## Results

| Measure | Forgejo | Kaneo |
| :--- | :--- | :--- |
| Restore path | restic, Longhorn backupstore, Longhorn volumes | restic, `pg_dumpall` file, fresh Postgres |
| Ready after clock start | 1h 19m | 3h 54m, of which the load and startup took under a minute |
| Data as of | About 03:00 UTC | 11:10 UTC |
| Behind live at the drill's start | About 12 hours | About 4 hours |
| Data check | 77 of 77 repos, no `git fsck` failures | All 42 tables match, 201 rows |
| App check | `/api/healthz` 200, `michael/homelab` cloned with 494 commits | `/api/health` 200 |

The 1h 19m includes about 19 minutes lost to the restic failure, so a clean run should take about an hour. That figure is an estimate until a run confirms it.

The recovery point depends on where in the day a failure lands. Longhorn backs up daily at 03:00 UTC, so Forgejo can lose up to a day of work. The 12 hours here is what this drill happened to measure.

## Timeline

All times are UTC. Phoenix is 7 hours behind.

| Time | Event |
| :--- | :--- |
| 14:58 | The clock starts. Terraform creates the cluster. |
| 15:10 | Terraform finishes after 12.5 minutes. |
| 15:11 | Flux is installed. Longhorn is ready about a minute later. |
| 15:13 | Secrets are applied and the restic Job starts. |
| 15:56 | Restic finishes all 33.5 GiB after 43 minutes, then exits 1 with 71,662 errors. |
| 16:13 | The first `volumes` run times out after 60 minutes waiting for the Job to complete. |
| 16:15 | The retry is deleted and `volumes` resumes against the restored data. |
| 16:16 | `drill-forgejo-data` reports restored. The script starts waiting on `drill-forgejo-db`. |
| 16:17 | Postgres recovers from its crash-consistent copy. Forgejo is ready at 16:17:36. |
| 16:17 to 18:51 | The script waits on a state that has already passed. Nobody notices. |
| 18:51 | The hang is found when the user asks for a status. The wait is stopped. |
| 18:52 | The Kaneo dump loads and Kaneo starts. The clock stops. |
| 18:54 | `verify` finishes. |
| 18:55 | `terraform destroy` starts. |
| 19:06 | All 21 resources are destroyed and the teardown check is empty. |

## Root causes

**Restic treated unsupported metadata as failure.** The data went through NFS, which refuses the `security.selinux` attribute saved in the backup. Every file and directory counted as an error, so restic exited 1 even though all the data arrived. All 10,771 log lines still retained were this one attribute. The log didn't keep all 71,662, so the other result is the file count: 36,691 files in the store and 33.463 GiB restored.

**The script waited for a state that doesn't last.** `wait_restored` required the volume to be `detached`. Forgejo's pod was already waiting for that volume, so Longhorn attached it as soon as the restore ended, between two polls. The loop had no timeout.

**Nothing was watching the wait.** The hang produced no output, and a silent command looks the same as a slow one. The assistant running the drill told the user the restore was under way and didn't check again until asked.

## Findings about production

- **`codeberg.org/forgejo/forgejo:15` is a floating tag.** The drill pulled a newer build than production runs, and it applied a migration production doesn't have, `v17a_add-action-run-workflow-source-commit`. This is the only table that restored higher than live. A production pod restart could make the same upgrade without any review.
- **35 of the 77 repositories have no refs.** Baseline and restore agree, so this is the known [Forgejo drift](2026-06-forgejo-repository-loss.md), not a restore fault. These repos count as matching, not as proof of restored data. At least one, `rubiconetic/qmd`, is marked non-empty in the database, which broke the first clone test.

## Differences from the baseline

Seven repositories differed from the baseline, the pattern expected from pushes after the snapshot. Two, `michael/anydoc` and `rubiconetic/perplexica`, only lack refs that live has. The other five hold older values for some refs. The ancestry check was run on `michael/homelab` alone, where restored `main` is an ancestor of live `main`. The other four weren't checked commit by commit.

18 of 129 Forgejo tables differed. Apart from the migration above, all were lower than live, as expected for a 12-hour-old copy: 3 issues, 3 pull requests, 9 comments, and CI history. Users, repositories and releases matched.

The Kaneo load reported 6 errors, and none mattered: the role and database already existed, and Postgres 16 doesn't recognise the Postgres 17 setting `transaction_timeout`. All 42 tables matched.

## What went well

- Every open question in the runbook resolved in favour of the plan: Longhorn 1.10.1 runs on EKS 1.34 and Amazon Linux 2023, the patched NFS server works, and the read-only IAM role restored the data with no production key on the cluster.
- Postgres recovered from a crash-consistent volume backup without help.
- The isolation held. Mirrors stayed off, and production and GitHub were unchanged.
- The teardown removed everything in about 11 minutes.

## What went wrong

- 2.5 hours of cluster time, about $0.75, went on a hang that a timeout would have ended.
- A status message implied progress without anyone having checked. The real state was only found when the user asked.
- The clock measures the drill's mistakes as well as the restore, so the Kaneo figure says little about Kaneo.
- The first clone test used an empty repository and proved nothing. It was repeated on `michael/homelab`.
- Three private repositories couldn't be cloned without a login, so the clone test covers one repository. `git fsck` covers the rest.

## Actions

| Action | Status |
| :--- | :--- |
| Skip `security.selinux` in the restic Job | Done, not yet run |
| Wait on `restoreRequired` alone in `wait_restored` | Done, not yet run |
| Pin the Forgejo image so upgrades go through review | Open |
| Add a timeout to `wait_restored` | Open |
| Decide whether a day of Forgejo data loss is acceptable | Open |
| Clean up the 35 repositories with no git data | Open |
| Re-run the drill to confirm both fixes and the one-hour estimate | Open |
