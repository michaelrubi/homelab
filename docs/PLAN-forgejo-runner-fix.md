# PLAN: Forgejo Runner Fix

This plan addresses the current "Mount Busy" error for the Forgejo runner and investigates why it hasn't worked historically.

## User Review Required

> [!IMPORTANT]
> **Workload Shift**: We will temporarily pin the Forgejo runner to the control-plane node (`thinkcentre01`) as requested, to avoid the unstable storage state on `thinkcentre02`.
> **Data Reset**: If the runner's persistent volume is corrupted or contains "zombie" registration data, we may need to format it or clear the registration file to trigger a fresh registration.

## Proposed Changes

### 1. Storage Recovery

We will perform a force detachment of the runner volume, similar to the Forgejo recovery.

#### [MODIFY] `manifests/productivity/forgejo.yaml`
- Add `nodeName: thinkcentre01` to the `forgejo-runner` StatefulSet spec.
- Scale the `forgejo-runner` to `0` temporarily during volume cleanup.

### 2. Connectivity & Registration

We will verify that the runner can reach the Forgejo instance and that the registration token is valid.

- Check if `http://forgejo-service.default.svc.cluster.local:3000` is accessible from a temporary pod on `thinkcentre01`.
- If registration fails, we will generate a new token via the Forgejo CLI (if possible) or the UI.

### 3. Docker-in-Docker (DinD) Stability

- Ensure the `privileged: true` mode is working correctly on `thinkcentre01`.
- Verify the runner can communicate with the local Docker daemon at `tcp://localhost:2375`.

---

## Open Questions

- **Registration Type**: Is this runner registered as a "Global" runner or a "Repository" specific runner? (The token format suggests a registration token, likely global).
- **Network Policy**: Are there any NetworkPolicies in the `default` namespace that might block traffic between the runner and the Forgejo service?

---

## Verification Plan

### Automated Tests
- `kubectl get pods -l app=forgejo-runner`: Verify both containers (`runner` and `docker`) are `Running`.
- `kubectl logs -f forgejo-runner-0 -c runner`: Check for "Runner successfully registered" or "Runner is online" messages.
- Run a test GIitea/Forgejo Action (if possible) to confirm job execution.

### Manual Verification
- Check the "Runners" section in the Forgejo Admin UI to see if the status is "Active".
