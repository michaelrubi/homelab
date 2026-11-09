# Runbook: Forgejo Postgres 14 → 17

Forgejo's database is a `postgres` sidecar in the `forgejo` pod. Postgres can't start a new major version on an old data directory, so the upgrade is a dump and restore into a **new** volume, `forgejo-db-pvc-17`. The old `forgejo-db-pvc` stays untouched, and it is the rollback.

Forgejo is Flux's own git source, which shapes the order below. Flux is suspended for the whole window, and the PR is merged **while Forgejo is still up**, because once Forgejo is scaled down, nothing can pull the change.

- **Downtime:** about 10 minutes of Forgejo, from step 4 to step 9.
- **Needs:** `kubectl` access, and this repo checked out on a machine with enough disk for the dump (a few hundred MB at most).
- **Don't push to Forgejo** between step 2 and step 9. Anything written after the dump in step 3 is lost.

## 0. Before the window

Confirm last night's Longhorn backup of `forgejo-db-pvc` completed (Longhorn UI → Backup). It's a second rollback path if the old volume itself goes wrong.

## 1. Suspend Flux

Suspend `flux-system` first. It applies `clusters/my-cluster/`, which contains the `manifests` Kustomization, and its next reconcile removes a `suspend` set with `kubectl patch`. That un-suspended Flux mid-window during the Forgejo 17 upgrade on 2026-11-09 ([forgejo-17-upgrade.md](forgejo-17-upgrade.md)).

```bash
kubectl -n flux-system patch kustomization flux-system --type merge -p '{"spec":{"suspend":true}}'
kubectl -n flux-system patch kustomization manifests --type merge -p '{"spec":{"suspend":true}}'
kubectl -n flux-system get kustomization flux-system manifests -o jsonpath='{range .items[*]}{.metadata.name}={.spec.suspend}{"\n"}{end}'
```

Both must print `true`.

## 2. Merge the PR and pull it locally

Merge it in the Forgejo UI. With Flux suspended, nothing is applied yet. Then:

```bash
git switch main && git pull
```

## 3. Dump the 14 cluster and record row counts

```bash
DUMP=~/forgejo-pg14-$(date +%Y%m%d-%H%M).sql.gz
kubectl exec deploy/forgejo -c postgres -- pg_dumpall -U forgejo | gzip > "$DUMP"
gunzip -c "$DUMP" | tail -3   # must end with "PostgreSQL database cluster dump complete"
ls -lh "$DUMP"

COUNTS='SELECT (SELECT count(*) FROM "user"), (SELECT count(*) FROM repository), (SELECT count(*) FROM issue), (SELECT count(*) FROM action);'
kubectl exec deploy/forgejo -c postgres -- psql -U forgejo -d forgejo -Atc "$COUNTS" | tee ~/forgejo-counts-before.txt
```

The dump stays on your workstation, which is deliberately off-cluster.

## 4. Stop Forgejo

```bash
kubectl scale deploy/forgejo --replicas=0
kubectl wait --for=delete pod -l app=forgejo --timeout=120s
```

## 5. Create the 17 volume and restore into it

```bash
kubectl apply -f docs/runbooks/forgejo-pg17-restore-pod.yaml
kubectl wait --for=condition=Ready pod/forgejo-pg17-restore --timeout=180s
gunzip -c "$DUMP" | kubectl exec -i forgejo-pg17-restore -- psql -U forgejo -d postgres -q 2>&1 | tee ~/forgejo-restore.log
```

One error is expected: `role "forgejo" already exists`, because the restore pod's initdb created it. Any other `ERROR` line means stop and go to rollback A.

## 6. Verify

```bash
kubectl exec forgejo-pg17-restore -- psql -U forgejo -d forgejo -Atc "$COUNTS" | diff - ~/forgejo-counts-before.txt && echo "counts match"
kubectl exec forgejo-pg17-restore -- psql -U forgejo -d forgejo -Atc "SHOW server_version;"
```

## 7. Remove the restore pod (keep the volume)

```bash
kubectl delete pod forgejo-pg17-restore
```

## 8. Start Forgejo on 17

Apply the merged manifest directly. The kustomization's patches don't touch Forgejo, so this matches what Flux would apply.

```bash
kubectl apply -f manifests/productivity/forgejo.yaml
kubectl rollout status deploy/forgejo --timeout=6m
```

## 9. Check it works

- Log in at git.rubiconetic.com and open a repo.
- Push a throwaway branch, then delete it.
- `kubectl logs deploy/forgejo -c forgejo | grep -i error` shows nothing new.

## 10. Resume Flux

```bash
kubectl -n flux-system patch kustomization manifests --type merge -p '{"spec":{"suspend":false}}'
kubectl -n flux-system patch kustomization flux-system --type merge -p '{"spec":{"suspend":false}}'
kubectl -n flux-system annotate gitrepository flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite
kubectl -n flux-system get gitrepository,kustomization
```

Both should show `Ready=True` on the merge commit.

## Rollback

**A. Before step 8** (Forgejo has not run on 17). Nothing live has changed, so:

```bash
kubectl delete pod forgejo-pg17-restore --ignore-not-found
kubectl scale deploy/forgejo --replicas=1
```

Then revert the merge commit on main once Forgejo is up, and resume Flux (step 10). Delete `forgejo-db-pvc-17` if you won't retry soon.

**B. After step 8.** The old deployment spec points at `forgejo-db-pvc`, which hasn't changed:

```bash
git revert -m 1 <merge-commit>
kubectl apply -f manifests/productivity/forgejo.yaml
kubectl rollout status deploy/forgejo
git push   # Forgejo is back up on 14 by now
```

Then resume Flux (step 10). Anything written to Forgejo while it ran on 17 is lost on rollback.

## Afterwards

After about two weeks on 17, remove the `forgejo-db-pvc` object from `manifests/productivity/forgejo.yaml` in a separate PR, along with its `$patch: delete` in `clusters/drill/apps/core/kustomization.yaml`. Flux prunes the volume. Delete the local dump at the same time.

Done on 2026-11-08 for the 14 → 17 upgrade. The old volume's last Longhorn backup (2026-10-24) stays in the backupstore.
