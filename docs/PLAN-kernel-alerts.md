# Plan: alert on kernel OOM kills and storage errors

**Target:** week of 2026-11-16 (finish by Sun 11-22, before the kured window)
**Why:** the kernel journal on both nodes shows two incidents that no alert caught and nothing in the repo records:

- **2026-10-21 20:58 UTC, thinkcentre01:** 1,556 `Out of memory: Killed process` lines in one minute, all Longhorn processes with `oom_score_adj:1000`. Longhorn's pods are BestEffort (no requests), so they are the kernel's first victims.
- **2026-10-22, both nodes:** `Buffer I/O error`, `EXT4-fs error` and aborted journals on Longhorn block devices (`sd*`, not the `nvme0` disk), including Prometheus's and a Postgres volume. Peaked at 16:10 UTC on node01, one minute before a planned reboot of node02. A `mount.nfs4` task also hung for 20+ minutes from 08:04 UTC.

No log shipping exists (no Loki/Promtail/Alloy), so alerts have to come from metrics.

## Steps

### 1. Investigate 10-21 before writing rules
- [x] `ssh cptc1 "journalctl _TRANSPORT=kernel -o short-iso --since '2026-10-21 20:50' --until '2026-10-21 21:05'"` and find the `invoked oom-killer` / `oom-kill:constraint=` lines. `CONSTRAINT_NONE` means the whole node ran out; `CONSTRAINT_MEMCG` means one cgroup hit its limit.
- [x] Check Prometheus for `node_memory_MemAvailable_bytes` and top pod memory around 20:50-21:00 UTC. Why didn't `NodeMemoryCritical` fire? (It needs 15m under 12%, and a spike can be shorter.)
- [x] Find out what was happening at the time: a rollout, a backup, or the Postiz stack.

#### Findings (checked 2026-11-18)

**What happened:** thinkcentre01 lost its connection to the NFS backup target, and stuck processes piled up until the node ran out of memory.

1. **19:31–20:36 UTC:** thinkcentre01's Tailscale connection kept flapping. UDP dropped out (`udp=false`), traffic fell back to the DERP relay, and at 20:14 even the LAX DERP connection failed for a while. Traffic between the nodes goes over Tailscale (`100.x`), so this hit NFS, the API server (6443) and node-exporter (9100). From 20:20, thinkcentre02's logs show timeouts reaching node01's API server.
2. **20:36:** `nfs: server thinkcentre02 not responding, timed out` begins on node01. The Longhorn backup target is `nfs://100.95.215.63:/var/lib/longhorn-backups`, over Tailscale.
3. **20:36–20:58:** Longhorn keeps polling the backup target, and every `longhorn` and `umount` process it starts blocks on the dead mount and stays there. No backup was running: the only RecurringJob runs at 03:00.
4. **20:58:28:** a global OOM (the messages read `Out of memory:`, not `Memory cgroup out of memory:`). In one second it killed **1,218 `longhorn`, 336 `umount` and 2 `longhorn-manager`** processes, all with `oom_score_adj` 1000. The `invoked oom-killer` and constraint header lines are missing because journald logged `/dev/kmsg buffer overrun, some messages lost`. Node01 has 7.8 GB of RAM, and 1,218 × ~7 MB RSS is more than it has free.

**Why nothing alerted:** Prometheus keeps only 15 days (the oldest data is 2026-11-03), so 10-21 can't be checked in it any more. The pile-up took about 20 minutes, and `NodeMemoryCritical` needs 15 minutes under 12%, so it may simply never have triggered. Node-exporter also scrapes over the same failing Tailscale link, so samples were probably missing too.

**Today, for comparison:** node01 has 32 `longhorn` processes (engines and replicas) and node02 has 23, with no `umount` processes and none in D state. The pile-up is not ongoing.

**10-22 has the same cause:** NFS timeouts from 08:02, then `mount.nfs4` hung for over 1,228 s. That is the same backup-target mount, about 11 hours later.

#### What this changes in step 2

- **`NodeFilesystemReadOnly` / `NodeFilesystemDeviceError` would not have caught 10-22.** Node-exporter skips `^/var/lib/kubelet/.+`, where Longhorn volumes are mounted. Right now it sees only one ext4 filesystem per node (`/dev/nvme0n1p2 /`), and no `/dev/sd*` devices at all. Either narrow `mount-points-exclude` so CSI mounts (`/var/lib/kubelet/pods/*/volumes/kubernetes.io~csi/*/mount`) are let back in, or drop these two rules and rely on `LonghornVolumeNotHealthy`.
- **Alert on the cause, not just the OOM.** Add:
  - `NodeBlockedProcesses`: `node_procs_blocked > 20` for 5m. Hung NFS calls show up as D-state processes.
  - `NFSClientTimeouts`: `rate(node_nfs_rpc_retransmissions_total[5m]) > 0` for 5m (first confirm the metric exists).
  - `LonghornBackupTargetUnavailable`: Longhorn's backup-target availability metric (look up its exact name in `/metrics`).
- `node_vmstat_oom_kill` exists on both nodes (currently 0), so `NodeOOMKill` works as planned. `longhorn_volume_robustness` exists for 48 volume series.
- Note the scrape problem: when the link between the nodes fails, node01's metrics can't be scraped either, so `up == 0` on node-exporter is a signal in its own right.
- Step 3 still matters (Longhorn processes are BestEffort with `oom_score_adj` 1000), but the stuck `longhorn` and `umount` processes are short-lived execs, so memory requests on the manager won't change who gets killed. Stopping the pile-up is the real fix.
- Off-plan, worth a separate look: should the backup target use the LAN IP instead of the Tailscale IP? And why did node01 lose UDP between 19:31 and 20:36?

### 2. Alert rules (`manifests/infrastructure/reliability-alerts.yaml`, `longhorn-alerts.yaml`)
Written 2026-11-18 on `feat/kernel-alerts`. Each expression was run against live Prometheus: all six parse, return series and aren't firing.
- [x] **`NodeOOMKill`** (warning): `increase(node_vmstat_oom_kill[1h]) > 0`. The window is 1h, not 5m, so the jump still shows if scrapes drop out around the kill.
- [x] **`ContainerOOMKilled`** (warning): last terminated reason `OOMKilled`, joined with a restart increase over 10m. The join was checked with `reason="Error"` (1 match).
- [x] **`PodProcessPileUp`** (critical, new): `container_processes > 150` in one pod for 5m. The 14-day maximum was 39.
- [x] **`NFSClientRetransmitting`** (warning, new): `increase(node_nfs_rpc_retransmissions_total[10m]) > 0` for 5m. It was 0 for 14 days.
- [x] **`LonghornVolumeDegraded`** (warning, **30m**, not 15m: kured reboots leave volumes degraded for up to 14 minutes) and **`LonghornVolumeFaulted`** (critical, 2m).
- [x] ~~`NodeFilesystemReadOnly` / `NodeFilesystemDeviceError`~~ dropped. Node-exporter can't see Longhorn mounts, so these would only cover the root disk.
- [x] ~~`NodeBlockedProcesses` (`node_procs_blocked`)~~ dropped. That metric counts I/O waits, and processes stuck on an NFS RPC may not be counted. `PodProcessPileUp` measures the pile-up directly.
- [x] ~~`LonghornBackupTargetUnavailable`~~ dropped. Longhorn 1.11 exports no backup-target metric (only `longhorn_backup_state`).
- [x] Follow the file's existing pattern: a comment on each rule saying which incident it would have caught, and a `description` with the first command to run.

### 3. Make Longhorn harder to OOM-kill
- [ ] Give `longhorn-manager` and the instance managers memory requests (via Helm values / `guaranteedInstanceManagerCPU` equivalents) so they leave BestEffort and lose `oom_score_adj:1000`. Size them from `kubectl top pods -n longhorn-system`.

### 4. Verify end to end
- [x] `kustomize build` and a server-side dry-run (both PrometheusRules accepted).
- [x] Check each `expr` in the Prometheus UI before merging, and confirm it returns series, not empty.
- [ ] Fire one test alert through ntfy and confirm it arrives. Don't name test alerts `Flux*`, or the Flux 2.10 alert routing will catch them.

### 5. Write it up
- [ ] Add `docs/postmortems/2026-10-oom-and-longhorn-io.md` covering 10-21 and 10-22, and link it from the README.
- [ ] Runbook note: use `journalctl _TRANSPORT=kernel` (or `-k -b all`) for history. Plain `journalctl -k` only shows the current boot.

## Out of scope
- Shipping kernel logs off the nodes (Loki or similar). Worth doing later; it would catch hung tasks and NIC flaps, which have no metric.
- The 11-15 18:48 UTC link drop on both nodes, which points at the switch, not the hosts.
