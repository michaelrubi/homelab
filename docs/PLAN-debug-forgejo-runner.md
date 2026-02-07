# Plan: Debug Forgejo Runner

## Context Refinement
The user is experiencing a `CrashLoopBackOff` on the `forgejo-runner` pod.
- **Error Log**: `Error: Failed to register runner: failed to save runner config: open /data/runner: permission denied`
- **Root Cause**: The `forgejo-runner` container runs as a non-root user (UID 1000) but the persistent volume mounted at `/data` is likely owned by root (UID 0), preventing the runner from writing its config and registration file.
- **Environment**: Kubernetes (homelab), Forgejo Service is healthy.

## User Review Required
> [!NOTE]
> This plan involves adding an `initContainer` to your StatefulSet. This is a standard pattern for fixing PVC permission issues in Kubernetes.

## Proposed Changes

### Manifest Configuration

#### [MODIFY] [forgejo.yaml](file:///home/michael/projects/homelab/manifests/productivity/forgejo.yaml)
- **Component**: `apps/v1/StatefulSet` named `forgejo-runner`
- **Change**: Add an `initContainer` to change ownership of the `/data` volume.
- **Details**:
    - Image: `busybox` or `alpine`
    - Command: `chown -R 1000:1000 /data`
    - VolumeMounts: `runner-data` at `/data`

## Verification Plan

### Automated Tests
1. **Apply Changes**: `kubectl apply -f manifests/productivity/forgejo.yaml`
2. **Watch Pods**: `kubectl get pods -w` (Wait for `forgejo-runner-0` to be `Running`)
3. **Check Logs**: `kubectl logs forgejo-runner-0 -c runner`
    - **Expectation**: "Runner registered successfully" or "Runner already registered". No permission denied errors.

### Manual Verification
- Check Forgejo UI (Site Administration > Runners) to see if the runner appears as "Online" or "Idle".
