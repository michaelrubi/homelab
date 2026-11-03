# Post-mortem: Secrets wiped, then silently reverted

**Dates:** 2026-09-11 and 2026-09-20 to 2026-10-24
**Impact:** 21 Secrets deleted from the cluster, wedged workloads, and a Kaneo outage. A previously exposed password was restored to use.

## Summary

There were two linked failures. First, a commit emptied `secrets.sops.yaml`, and Flux treated that as an instruction to delete every Secret in it. Recovery relied on a local plaintext copy, which worked. Nine days later, the same habit re-encrypted from a copy that had gone stale, silently dropping values and reverting a rotated password. Nothing broke until Kaneo restarted five weeks later.

## Timeline

| Date | Event |
| :--- | :--- |
| 09-11 | `c5c35d1`, a runner token rotation, leaves `secrets.sops.yaml` at zero bytes. |
| 09-11 | Flux prunes all 21 Secrets. Running pods keep their environment, so nothing looks wrong at first. |
| 09-11 | `forgejo-runner-0` and the Renovate job restart and wedge on `CreateContainerConfigError`. |
| 09-11 | `449a20b` restores all 21 Secrets and 89 keys from local plaintext. The result is checked against the pre-wipe blob. |
| 09-18 | The Kaneo password, exposed in Git, is rotated (`87cb13f`). |
| 09-20 | `4fd8b34` re-encrypts from a plaintext copy older than that rotation. |
| 09-20 | `COUCHDB_SECRET` is found missing and restored (`e15f398`). The other damage goes unnoticed. |
| 10-24 | A Kaneo rollout crash-loops, because `DATABASE_URL` is gone and the password is the old exposed one. |
| 10-24 | PRs #142 and #143 fix Kaneo and rotate the password again. |

## Root causes

**Prune treats absence as intent.** `prune: true` is what makes Git the source of truth, and it also means an empty file is a valid order to delete everything.

**CI couldn't see the secrets file.** Validation skips Secrets because encrypted files don't match the schema, so a zero-byte file passed.

**A plaintext copy became a second source of truth.** A whole-file re-encrypt replaces everything with the state of that copy, including any change made since it was taken.

**Running pods hide missing Secrets.** Environment variables are read at container start, so the failure waits for the next restart. Kaneo took five weeks.

## What changed

| Action | Status |
| :--- | :--- |
| Move the plaintext copy out of the repo so tools can't pick it up | Done |
| Change secrets only with `sops edit`, and compare decrypted lines before committing | Done, by convention |
| Build Kaneo's `DATABASE_URL` from `kaneo-db-secrets`, so one password has one copy | Done |
| Rotate the exposed Kaneo password | Done |
| Fail CI when a SOPS file is empty or a previously known Secret disappears | Open |
| Alert on workloads that reference a missing Secret or key | Open |

## Lessons

- Destructive automation needs a guard against empty input. "Nothing here" and "delete everything" shouldn't be the same signal.
- Recovering from an unofficial copy can succeed once and teach the wrong habit.
- A clean restart is a test. Long-running pods can hide broken configuration for weeks.
- Rotating a secret isn't finished until every copy of the old value is gone.

## Evidence

Commits `c5c35d1`, `449a20b`, `87cb13f`, `4fd8b34`, `e15f398`, `30635ad`, and `150ae76`.
