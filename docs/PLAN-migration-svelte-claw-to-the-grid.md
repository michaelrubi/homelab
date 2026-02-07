# Plan: Migration - Svelte Claw to The Grid

## Goal
Replace the existing `svelte-claw` deployment with `the-grid` (version `v0.1.0`) in the Kubernetes cluster. This involves creating new manifests, updating configuration references, and removing the old deployment.

## User Review Required
> [!IMPORTANT]
> **Environment Variables**: The `svelte-claw` deployment used `AGENT_SECRET`, `OPENCLAW_GATEWAY_TOKEN`, and `OPENCLAW_IP_ADDRESS`. These are **NOT** present in `the-grid-secrets`. I have assumed they are not required for `the-grid`. Please verify this.

> [!NOTE]
> **Service Port**: I plan to expose `the-grid` on the same external port (`5717`) as `svelte-claw` for continuity, unless you prefer a different port.

## Proposed Changes

### Manifests

#### [NEW] [the-grid.yaml](file:///home/michael/projects/homelab/manifests/productivity/the-grid.yaml)
Create a new deployment manifest for `the-grid`.
- **Image**: `git.rubiconetic.com/rubiconetic/the-grid:v0.1.0`
- **Secrets**: Use `the-grid-secrets`
- **Env Vars**:
    - `ORIGIN`
    - `ADMIN_EMAIL`
    - `ADMIN_PASSWORD`
    - `POCKETBASE_URL`
    - `PUBLIC_POCKETBASE_URL`
    - `SVELTE_CLAW_URL` (from secrets)
- **Service**: `the-grid-service` on port `5717`.

#### [MODIFY] [homepage-app.yaml](file:///home/michael/projects/homelab/manifests/infrastructure/homepage-app.yaml)
Update the `homepage` deployment to reference the new secrets.
- Rename `HOMEPAGE_VAR_SVELTECLAW_URL` to `HOMEPAGE_VAR_THEGRID_URL`.
- Map it to `the-grid-secrets` key `SVELTE_CLAW_URL`.

#### [MODIFY] [homepage-config.yaml](file:///home/michael/projects/homelab/manifests/infrastructure/homepage-config.yaml)
Update the homepage configuration to display "The Grid".
- Change "Svelte Claw" to "The Grid".
- Update `href` to use `{{HOMEPAGE_VAR_THEGRID_URL}}`.

#### [DELETE] [svelte-claw.yaml](file:///home/michael/projects/homelab/manifests/productivity/svelte-claw.yaml)
Remove the old deployment manifest.

## Verification Plan

### Automated Verification
1.  **Deployment Status**:
    ```bash
    kubectl rollout status deployment/the-grid
     ```
2.  **Service Connectivity**:
    ```bash
    curl -I http://<node-ip>:5717
    ```

### Manual Verification
1.  **Homepage**: Check the dashboard to ensure "The Grid" link appears and works.
2.  **Logs**: Check pods logs for any startup errors.
    ```bash
    kubectl logs -l app=the-grid
    ```
