# Post-mortem: Five days of silent alerts

**Dates:** 2026-09-06 to 2026-09-11
**Duration:** 5 days undetected
**Impact:** No metrics or alerts for 5 days, repeated pod restarts across the cluster, and no database dumps. No data loss.

## Summary

A routine node reboot moved nearly every workload onto one node, which ran out of memory. Prometheus had already filled its volume and was crash-looping. Even if it had been healthy, nothing would have reached me, because Alertmanager's only receiver was the Helm chart's default, `null`. I found out by looking, five days later.

## Timeline

| Date | Event |
| :--- | :--- |
| Before 09-06 | Hand-written Longhorn alerts, added after an August outage, fire into the `null` receiver. |
| 09-06 | A kured reboot reschedules nearly every workload onto thinkcentre01. |
| 09-06 to 09-11 | The node sits at 471 MiB available of 7.6 GiB with 2 GiB of swap in use. Probes time out and the kubelet kills healthy pods. |
| 09-06 to 09-11 | Prometheus crash-loops 1,537 times on a full WAL volume. The `pg_dumpall` job fails 3,908 NFS mounts. A Postiz sidecar restarts 1,961 times. |
| 09-11 | Investigation starts. Receivers, retention, probes, and resource requests are fixed. |
| 09-11 | A rollout triggered by the fix deadlocks on a ReadWriteOnce volume, and `Recreate` strategy resolves it. |
| 09-12 | Permanently firing alerts that didn't describe this cluster are retired. |

## Root causes

**Alerts had nowhere to go.** Alertmanager was installed with its default `null` receiver and never tested end to end. Rules existed, which made alerting look finished.

**The scheduler was working from wrong numbers.** Several pods had no requests, and Postiz requested 512 MiB while holding about 2.4 GiB. The scheduler places pods by requests, so thinkcentre01 looked 1.8 GiB emptier than it was.

**Prometheus had no storage bound.** With no retention cap, the time series database grew until the 10 GiB volume was full.

**A probe had a real cost.** The Postiz sidecar's catch-all route forwarded health checks upstream. Each probe was a billed API call that returned 404 and counted as a failure, at about 8,600 junk requests a day.

## What changed

| Action | Status |
| :--- | :--- |
| Route alerts to ntfy instead of `null` | Done |
| Send Watchdog to a healthchecks.io dead-man's switch, which catches Prometheus itself dying | Done |
| Add `retentionSize` of 12 GiB and grow the volume to 20 GiB | Done |
| Right-size requests from measured usage for the workloads that were understated or had none | Done |
| Use `tcpSocket` for the Postiz sidecar probe | Done |
| Use `Recreate` on single-replica deployments with ReadWriteOnce volumes | Done |
| Add alerts for stale backups, node memory, and swap thrashing | Done |
| Remove CPU limits; WAL replay had 703 of 1,125 periods throttled | Done |
| Add a classifier so warnings stay worth reading ([alert-router](../../manifests/infrastructure/alert-router.yaml)) | Done |

## Lessons

- An alert isn't working until you've seen it arrive. Rules prove nothing about delivery.
- The monitoring system can't report its own death, so that signal has to leave the cluster.
- Requests are the only information the scheduler has. If they're wrong, a healthy-looking node can be full.
- Five noisy failures looked like one problem. The node's memory shortage made everything else harder to see.

## Evidence

Commits `9f70531`, `a6416e5`, `449a20b`, and `4fd8b34`.
