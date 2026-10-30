# Troubleshooting: Forgejo Recovery (Node Crash)

This document explains the fix applied to restore `git.rubiconetic.com` after a worker node crash led to 502 errors and "stale" storage mounts.

## 📋 Symptoms

- **HTTP 502 Bad Gateway**: Internal services like Forgejo were inaccessible from the internet.
- **Pod Status**: Internal pods (Forgejo, Postgres) were stuck in `ContainerCreating`.
- **CSI Error**: `kubectl describe pod` revealed errors like:
  > `MountVolume.MountDevice failed... exit status 32: already mounted or mount point busy.`

## 🔍 Root Cause

When `thinkcentre02` crashed and rebooted, the **Longhorn / CSI Driver** lost track of the local mounts on the host. When the node came back up, the host operating system held a "zombie" lock on the block devices, preventing Kubernetes from safely re-attaching the volumes.

## 🛠️ The Fix

### 1. Kernel Resource Limits (Applied by User)

Before shifting workloads, the underlying cause of the "unresponsive" node was likely hitting `inotify` limits. The following was applied to both nodes to prevent `k3s` from failing under high file-tracking load:

```bash
# /etc/sysctl.d/99-k3s-inotify.conf
fs.inotify.max_user_instances=8192
fs.inotify.max_user_watches=524288
```

### 2. Breaking the Storage Lock

To clear the "Mount Busy" error, we performed a **Force Detachment**:

- Scaled Forgejo to `0` replicas.
- Deleted the specific `VolumeAttachment` resources in Kubernetes that pinned the volumes to the old node state.

### 3. Node Workload Shift (Control Plane)

As `thinkcentre02` was still reconciling its storage layer, the Forgejo deployment was temporarily patched to run on the control-plane node (`thinkcentre01`) to ensure service availability:

```bash
kubectl patch deployment forgejo --patch '{"spec": {"template": {"spec": {"nodeName": "thinkcentre01"}}}}'
```

## ✅ Result

Forgejo recovered successfully on `thinkcentre01` and the Runner is stabilized.

> [!NOTE]
> **Reverting the Shift**: Once you are confident that `thinkcentre02` is completely stable and Longhorn has finished its volume rebuilds, you can remove the `nodeName` override from `manifests/productivity/forgejo.yaml` to allow it to return to the worker node.
