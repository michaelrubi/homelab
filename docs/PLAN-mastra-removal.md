# PLAN-mastra-removal.md

## Goal Description
Completely remove the Mastra automation service from the homelab environment, including Kubernetes resources and the backend database.

## User Review Required
> [!IMPORTANT]
> **Database Deletion**: This will permanently drop the `mastra` database. Ensure no data needs to be preserved.
>
> **Secret Cleanup**: The user will manually manage the removal of `mastra-secrets` from `secrets.sops.yaml`.

## Proposed Changes

### Infrastructure Cleanup
1. **Kubernetes Resources**: Delete the Deployment and Service defined in [mastra.yaml](file:///home/michael/projects/homelab/manifests/automation/mastra.yaml).
2. **Database Cleanup**: Drop the `mastra` database from the shared Postgres instance.

### File Deletion
1. [DELETE] [mastra.yaml](file:///home/michael/projects/homelab/manifests/automation/mastra.yaml)
2. [DELETE] [PLAN-mastra-setup.md](file:///home/michael/projects/homelab/docs/PLAN-mastra-setup.md)

## Implementation Steps

### Phase 1: Resource Deletion (Live)
1. Delete Mastra resources from the cluster:
   `kubectl delete -f manifests/automation/mastra.yaml`
2. Verify:
   `kubectl get pods -n automation -l app=mastra` returns no results.

### Phase 2: Database Cleanup
1. Exec into the postgres pod and drop the `mastra` database:
   `kubectl exec -it -n default postgres-dfb448d4b-f87f5 -- psql -U n8n -c "DROP DATABASE mastra;"`
2. Verify:
   `kubectl exec -it -n default postgres-dfb448d4b-f87f5 -- psql -U n8n -l`

### Phase 3: File Cleanup
1. Delete the files from the repository:
   `rm manifests/automation/mastra.yaml`
   `rm docs/PLAN-mastra-setup.md`

## Verification Plan

### Automated Tests
- `kubectl get pods -n automation -l app=mastra` (Should be empty)
- `grep -r "mastra" .` (Verify no remaining references except in user-managed files)

### Manual Verification
- Check the database list to ensure `mastra` is gone.
