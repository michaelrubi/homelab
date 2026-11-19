# Post-mortem: second EKS restore drill

**Date:** 2026-11-19, 15:29 to 17:08 UTC
**Duration:** About 1 hour 39 minutes, including teardown
**Impact:** None on production. This was a planned drill, and it cost about $0.50 (estimated from the hourly rate, not yet billed).

## Summary

Forgejo was restored from the S3 backup into a temporary EKS cluster, using last night's automated snapshot. The restore passed: all 86 repositories came back, every one passed `git fsck`, and `michael/homelab` restored to an ancestor of live `main`. Both fixes from the [first drill](2026-10-eks-restore-drill.md) held: restic exited 0, and the volume wait ended as soon as each restore finished. Forgejo was ready 1 hour 26 minutes after the clock started, slower than the first drill's 1 hour 19 minutes. Restic took 63 minutes, and only about 11 of them were spent downloading.

This was also the first restore of Forgejo 17 and its Postgres 17 volume, on EKS 1.35 with Longhorn 1.11.3.

## Results

| Measure | Forgejo |
| :--- | :--- |
| Restore path | restic, Longhorn backupstore, Longhorn volumes |
| Ready after clock start | 1h 26m (15:29:39 to 16:55:30) |
| Data as of | 03:02 UTC, the nightly Longhorn backup |
| Behind live at the drill's start | About 12.5 hours |
| Data check | 86 of 86 repos, no `git fsck` failures |
| App check | `/api/healthz` 200, `michael/homelab` cloned with 673 commits |

Restored `michael/homelab` `main` is PR 236, four commits behind live and an ancestor of it. The four are the Renovate merges made after the 03:02 backup.

## Timeline

All times are UTC.

| Time | Event |
| :--- | :--- |
| 15:29 | A first apply fails before creating anything: Renovate had moved the AWS provider lock to 6.73.0, so Terraform needed `init`. The clock restarts after `init` at 15:29:39. |
| 15:42 | Terraform finishes after 13 minutes. |
| 15:43 | Flux is installed, and Longhorn comes up. |
| 15:49 | Secrets are applied and restic starts. |
| 15:49 to 16:15 | Restic walks the snapshot's trees. It creates about 40,000 directories and no files, over one connection at about 40 KB/s. |
| 16:15 to 16:26 | Restic downloads 41 GB over four connections, about 3.5 GB a minute. |
| 16:26 to 16:52 | Restic walks the trees again to set metadata, at the same slow rate. |
| 16:52 | Restic exits 0: 81,975 files and directories, 40.19 GiB, in 1:03:12. |
| 16:53 | Both volumes report restored. |
| 16:55 | Forgejo is available. The clock stops. |
| 16:57 | `verify` finishes. |
| 16:58 to 17:08 | `terraform destroy` removes all 21 resources, and the teardown check is empty. |

## Root cause

**Restic ran without a cache.** The Job passes `--no-cache`, so every tree restic needs is a separate small S3 request, made one after another. A restore walks the trees twice, once to plan and once to set metadata. Each walk took about 26 minutes, while the data itself took 11. The backup has also grown since October, from 33.5 GiB to 40.2 GiB and to about 82,000 files and directories, which lengthens both walks.

The first drill used the same flag and took 43 minutes in all. Its walks weren't timed separately, so how much the backup's growth added is unknown.

## What the fixes from the first drill did

- **Skipping `security.selinux`:** restic exited 0 this time, against 71,662 errors before.
- **Waiting on `restoreRequired` alone:** `drill-forgejo-data` passed through `detached` between polls, the state that hung the first drill, and the wait ended normally.
- **Timeouts on every wait:** none were reached.

## Differences from the baseline

Three repositories' refs differed: `michael/homelab`, `michael/anydoc` and `rubiconetic/cartsplit`. Only `michael/homelab` was checked for ancestry. `michael/anydoc` is a pull mirror whose sync fails in production with missing objects, so it should be investigated on its own.

18 Forgejo tables differed. All but one were lower than live, as expected for a 12-hour-old copy: 4 issues, 3 pull requests, 17 comments and CI history. `branch` restored 7 rows higher, probably because branches were deleted after the snapshot, such as merged Renovate branches. That wasn't checked.

## What went well

- No errors and no hangs. The step ran from start to finish without anyone stepping in.
- Progress was checked every one to two minutes, so the slow phase was found and explained while it happened.
- Postgres 17 recovered from a crash-consistent volume backup on its first drill.
- Isolation held. Mirrors stayed off, and production and GitHub were unchanged.

## What went wrong

- Restic spent about 50 minutes on round trips, so the recovery time went up despite both fixes working.
- Restic prints nothing between its first line and its summary, so its progress could only be inferred from network counters and file counts.
- The Terraform default was still Kubernetes 1.34, which leaves standard support on 2026-12-01. The drill passed 1.35 by hand.
- The first `terraform apply` failed on a stale provider cache after Renovate bumped the lock file.

## Actions

| Action | Status |
| :--- | :--- |
| Give restic a cache in an `emptyDir` instead of `--no-cache` | Done, not yet run |
| Default the drill to Kubernetes 1.35 | Done |
| Run `terraform init` before the clock starts, since Renovate updates the lock file | Done, added to the runbook's preflight |
| Investigate `michael/anydoc`'s missing objects and the four broken push mirrors | Open |
| Re-run the drill to confirm the cache and get a recovery time under an hour | Open |
