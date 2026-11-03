# Post-mortem: Forgejo repositories lost their git data

**Dates:** Bare repositories re-created 2026-06-01 and 2026-07-06; found 2026-09-20; mirror impact found 2026-10-30
**Duration:** About 3.5 months undetected
**Impact:** 49 of 68 repositories lost their hooks. 37 lost all git objects, some of them hundreds of megabytes. Five GitHub push mirrors stopped updating.

## Summary

Bare repositories under `/data/git/repositories` were re-created with plain `git init --bare`, outside Forgejo. The web UI kept working from database records, so nothing looked broken. Hooks were gone, so pushes stopped updating the database, and 37 repositories had no objects at all. By the time a banner led me to it, Longhorn's 7-day backup retention had long since aged out the good data.

## Timeline

| Date | Event |
| :--- | :--- |
| 05-29 | Last successful push to the GitHub homelab mirror. |
| 06-01 | Bare repositories are re-created, the same day Forgejo is pinned to thinkcentre01 for a multipathd problem. |
| 07-06 | A second batch of repositories is re-created. |
| 09-20 | The "out of synchronization" banner is traced to `checkOutdatedBranch()` comparing Postgres against git. |
| 09-20 | Hooks and HEADs are repaired with `gitea doctor`, and branch data is resynced from Site Administration. |
| 10-30 | The GitHub mirror's generic "Unexpected error" is traced to the same event. Forgejo logs show `No such remote`. |

## Root causes

**Trigger:** the exact command or script that ran `git init --bare` is not known. The timing points to the storage recovery work on 06-01, but no record confirms it. That gap is itself a finding.

**Git data and database state can diverge silently.** Forgejo keeps metadata in Postgres and content on disk. The UI reads the first, so the second can vanish without a visible error.

**Nothing verified repository contents.** Monitoring covered whether Forgejo was up, not whether its repositories were intact.

**Retention was shorter than detection.** Backups were kept for 7 days, and the failure took 3.5 months to notice. Backups can't protect against a failure you won't see within the retention window.

**Mirror credentials lived with the repository.** The push mirror's remote, stored in the bare repository's git config, disappeared with it. Each later sync failed with a generic error that nobody was alerted to.

## What changed

| Action | Status |
| :--- | :--- |
| Repair hooks and repository HEADs | Done |
| Resync branch data from git to the database | Done |
| Find and rebuild the broken push mirrors | In progress |
| Add a scheduled `git fsck`-style integrity check with an alert | Open |
| Alert when a push mirror reports an error | Open |
| Keep monthly backups long enough to outlast slow-burn failures | Open |

## Lessons

- A healthy UI proves the UI is healthy.
- Retention should reflect how long a failure can go unnoticed, not only how much disk is available.
- Never change an application's data directory behind its back, even during a recovery.
- Write down what you do during an incident. The missing record is why the trigger remains unknown.
- A generic error on a background job deserves an alert, because nobody is watching the page it appears on.

## Evidence

Forgejo logs from 2026-10-30 and commit `3b507cb`. Runbook for related storage recovery: [forgejo-node-crash-recovery](../runbooks/forgejo-node-crash-recovery.md).
