# Post-mortem: an NFS stall, a 1,556-process OOM, and read-only Longhorn volumes

**Date:** 2026-10-21 19:31 to 2026-10-22 16:13 UTC
**Duration:** Two incidents. The OOM build-up lasted about 22 minutes (10-21), and the volumes were read-only for about 2 minutes before a reboot (10-22).
**Impact:** thinkcentre01 ran out of memory and Longhorn's manager was killed. On 10-22, 18 Longhorn volumes on thinkcentre02 aborted their ext4 journals, and 6 filesystems across the two nodes went read-only. No data loss has been found, but none was looked for specifically. No alert fired for either incident. Both were found on 2026-11-18 while reading the kernel journal.

## Summary

thinkcentre01's Tailscale connection lost UDP and kept falling back to the DERP relay. The nodes reach each other over Tailscale, and so does the Longhorn backup target (an NFS export on thinkcentre02), so NFS stopped answering. Longhorn polls the backup target every 5 minutes, and each `longhorn` and `umount` process it started got stuck on the dead mount. They piled up until a global OOM killed 1,556 processes in one second. The next day NFS stalled again, and a few minutes after the Longhorn instance manager on thinkcentre02 was replaced, 18 volumes aborted their ext4 journals and 6 filesystems went read-only. The node was rebooted by hand. No rule was watching OOM kills, NFS, process counts or Longhorn volume health, so nothing paged.

## Timeline

All times are UTC. Phoenix is 7 hours behind.

| Time | Event |
| :--- | :--- |
| 10-21 19:31 | thinkcentre01's Tailscale starts flapping: `udp=false`, peers reached `via=derp`. |
| 10-21 20:14 | The LAX DERP connection fails too (`no-derp-connection`), then recovers at 20:15. |
| 10-21 20:20 | thinkcentre02 times out reaching node01's API server (6443) and node-exporter (9100). |
| 10-21 20:36 | `nfs: server thinkcentre02 not responding, timed out` begins on node01. Stuck `longhorn` and `umount` processes start to pile up. |
| 10-21 20:58:28 | Global OOM on node01: 1,218 `longhorn`, 336 `umount` and 2 `longhorn-manager` processes killed, all with `oom_score_adj` 1000. journald reports `/dev/kmsg buffer overrun`. |
| 10-22 08:02 | NFS timeouts on node01 again. |
| 10-22 08:04–08:22 | `mount.nfs4` is reported hung for 122 s, rising to 1,228 s, then reports are suppressed. |
| 10-22 15:59 | Commit 6e94d04 changes the backup target from `thinkcentre02` to its Tailscale IP and moves several workloads to node01. |
| 10-22 16:07:59 | A new instance-manager pod starts on thinkcentre02. |
| 10-22 16:08:28 | Every iSCSI session to the old instance manager (10.42.1.121) drops. 18 ext4 journals abort on node02, and 5 filesystems are remounted read-only. |
| 10-22 16:09:35 | thinkcentre02 is rebooted by hand (`systemd-logind`, not kured). |
| 10-22 16:09:57 | One filesystem on node01 (`sdo`) also goes read-only. |
| 10-22 16:12:57 | thinkcentre02 is back up. The last NFS timeout on node01 is at 16:13:24. |
| 11-18 | Both incidents are found in the kernel journal while planning OOM alerts. |

## Root causes

**NFS is reached over a link that can fail without anyone noticing.** The backup target and the postgres-dumps export are both on thinkcentre02, and both are mounted over Tailscale. When node01 lost UDP, Tailscale fell back to a relay and then briefly lost the relay too. NFS has no fast way to fail, so callers wait.

**Longhorn keeps starting processes against a dead backup target.** Each poll starts processes that never return when the mount hangs. They are BestEffort and have `oom_score_adj` 1000. That makes them the kernel's first victims, but nothing stops more of them being started.

**The read-only volumes had a separate trigger, and we don't know what it was.** At 16:08 the instance manager serving every volume engine on thinkcentre02 was replaced, and its iSCSI targets went with it. The old pod's deletion isn't in thinkcentre02's logs, and the API server keeps no audit log. It may have been a manual restart during the recovery. Commit 6e94d04 rescheduled several workloads 9 minutes earlier, but that alone shouldn't restart an instance manager.

**No metric covered any of it.** `NodeMemoryCritical` needs 15 minutes under 12%, and node01 couldn't be scraped reliably while its link was failing. Node-exporter ignores `/var/lib/kubelet`, where Longhorn volumes are mounted, so read-only Longhorn filesystems are invisible to filesystem metrics. Prometheus keeps 15 days, so by the time this was found the metrics were gone, and only the kernel journal was left.

## What went well

- The kernel journal kept 4 weeks of history across reboots, which was enough to rebuild both incidents.
- thinkcentre02 was back up 3 minutes 22 seconds after the reboot.

## What went wrong

- Nobody knew either incident had happened for four weeks.
- journald dropped the `invoked oom-killer` header lines in the burst, so the kernel's own record of the OOM's trigger is lost.
- Plain `journalctl -k` shows only the current boot, which hides incidents like these after a reboot.
- The 10-22 recovery was done without a written account, so the instance-manager restart can't be explained now.

## Actions

| Action | Status |
| :--- | :--- |
| Alert on kernel OOM kills (`NodeOOMKill`) and container OOM kills (`ContainerOOMKilled`) | Done (PR 235) |
| Alert on stuck-process pile-ups in any pod (`PodProcessPileUp`, critical) | Done (PR 235) |
| Alert on NFS client retransmissions (`NFSClientRetransmitting`) | Done (PR 235) |
| Alert on degraded and faulted Longhorn volumes | Done (PR 235) |
| Send a test page through ntfy after the merge and confirm it on the phone | Done 2026-11-18 |
| Decide whether the backup target and dump export should use the LAN IP instead of Tailscale | Open |
| Find out why thinkcentre01 lost Tailscale UDP on 10-21 | Open |
| Ship kernel logs off the nodes, so hung tasks and link flaps have a record after a reboot | Open |

## Lessons

- A dependency on NFS is also a dependency on the network path to it. On this cluster, that path is Tailscale.
- A process that can hang will pile up if something keeps starting it. Count processes, not just memory.
- Filesystem metrics that skip `/var/lib/kubelet` can't see Kubernetes volumes at all.
- Search with `journalctl _TRANSPORT=kernel` or `journalctl -k -b all`. Plain `journalctl -k` only covers the current boot.
- Write down what you did during a recovery while you do it. Four weeks later, the logs can't say who restarted what.

## Evidence

Kernel journals on both nodes (`journalctl _TRANSPORT=kernel`), `tailscaled` and `iscsid` logs on both nodes, commit 6e94d04, PR 235, and the investigation in [`docs/PLAN-kernel-alerts.md`](../PLAN-kernel-alerts.md).
