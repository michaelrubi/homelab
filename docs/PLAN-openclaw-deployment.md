# Plan: OpenClaw Deployment

## Goal
Deploy the OpenClaw agent to the K3s cluster using declarative Kubernetes manifests, adhering to the repository's existing structure (`manifests/` directory) and secret management (SOPS).

## Implementation Strategy
1.  **Directory Structure**: Use `manifests/automation/` for the OpenClaw manifests, consistent with other automation tools like n8n.
2.  **Secret Management**:
    -   Define a new Secret `openclaw-secrets` containing `OPENCLAW_GATEWAY_TOKEN`, `ANTHROPIC_API_KEY`, and `OPENAI_API_KEY`.
    -   Since `manifests/secrets/secrets.sops.yaml` is encrypted with SOPS, I cannot modify it directly. I will generate the standard YAML snippet for the user to append using `sops`.
3.  **Manifest Creation**:
    -   Create a single file `manifests/automation/openclaw.yaml` containing:
        -   `Namespace`: `openclaw`
        -   `PersistentVolumeClaim`: `openclaw-data` (5Gi, RWO)
        -   `Deployment`: `openclaw-gateway`
            -   Image: `openclaw/openclaw:latest`
            -   Security Context: `fsGroup: 1000`
            -   Volume Mount: `openclaw-data` -> `/home/node/.openclaw`
            -   Env Vars: `NODE_ENV=production`, plus references to `openclaw-secrets`.
        -   `Service`: `openclaw-service` (ClusterIP, Port 18789).

## Proposed Changes

### [NEW] [openclaw.yaml](file:///home/michael/projects/homelab/manifests/automation/openclaw.yaml)
-   **Namespace**: `openclaw`
-   **PVC**: `openclaw-data`
-   **Deployment**: `openclaw-gateway`
-   **Service**: `openclaw-service`

### [MODIFY] [secrets.sops.yaml](file:///home/michael/projects/homelab/manifests/secrets/secrets.sops.yaml)
-   **Action**: User to manually append the `openclaw-secrets` block using `sops`.
-   **Content**:
    ```yaml
    apiVersion: v1
    kind: Secret
    metadata:
      name: openclaw-secrets
      namespace: openclaw
    type: Opaque
    stringData:
      OPENCLAW_GATEWAY_TOKEN: "placeholder"
      ANTHROPIC_API_KEY: "" # Placeholder
      OPENAI_API_KEY: ""    # Placeholder
    ```

## Verification Plan

### Automated Verification
None (Manifest generation only).

### Manual Verification
1.  **Secret Creation**:
    -   User runs `sops manifests/secrets/secrets.sops.yaml` and adds the `openclaw-secrets` block.
2.  **Apply Manifests**:
    -   Run `kubectl apply -f manifests/automation/openclaw.yaml`.
    -   *Note*: Ensure the secret is applied *before* the deployment, or strict ordering might fail if not applied atomically.
3.  **Verify Pod Status**:
    -   `kubectl get pods -n openclaw` - Should be `Running`.
    -   `kubectl logs -n openclaw -l app=openclaw-gateway` - Check for startup logs.
4.  **Verify Service**:
    -   `kubectl get svc -n openclaw` - `openclaw-service` should exist.
5.  **Verify Storage**:
    -   `kubectl get pvc -n openclaw` - `openclaw-data` should be `Bound`.

## Questions / Notes
-   **Ingress**: The plan does not include an Ingress resource as it was not requested. If external access is required, an Ingress should be added.
-   **GitOps**: If this cluster is managed by Flux/ArgoCD, ensure `manifests/automation` is monitored by the synchronization controller.
