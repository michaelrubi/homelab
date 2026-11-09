# Runbook: Forgejo 15 → 17

PR #194 moves `codeberg.org/forgejo/forgejo` from `15.0.11` to `17.0.1`, skipping 16. Forgejo runs its database migrations on first start, and they are one-way: Forgejo 15 won't start on a database that 17 has migrated. A `pg_dump` taken just before the upgrade is the rollback.

Forgejo is Flux's own git source, so the order follows [forgejo-postgres-upgrade.md](forgejo-postgres-upgrade.md). Flux is suspended for the whole window, and the PR is merged **while Forgejo is still up**.

- **Downtime:** a few minutes, from step 4 until the pod is ready. The startup probe allows 5 minutes for migrations.
- **Needs:** `kubectl` access, and this repo checked out on the workstation with room for the dump.
- **Don't push to Forgejo** between step 3 and step 6. A rollback restores the database to step 3, and anything written after that is lost.
- **Support:** 17.0 is not an LTS release. It's supported until **28 January 2027**, so the move to 18 has to happen before then. 15.0 LTS would have lasted until 15 July 2027.

## Breaking changes checked against this setup

Checked 2026-11-09 against the [v16.0](https://forgejo.org/2026-07-release-v16-0/) and [v17.0](https://forgejo.org/2026-10-release-v17-0/) announcements. The full release notes on Codeberg weren't readable at the time, so re-read them before starting.

| Change | Version | Effect here |
|---|---|---|
| Containers no longer trust all proxies by default | 16 | None. `ENABLE_REVERSE_PROXY_AUTHENTICATION` isn't set |
| Git no longer follows HTTP redirects for mirrors | 16 | None. All 15 pull-mirror upstreams answered 200 without a redirect. `Neumi-AI/neumiracle` and `Not-Operations/takeofffinancial-marketing-dashboard` answer 401, which predates this upgrade |
| Skipped checks show as skipped, not succeeded | 16 | None. `homelab` has no branch protection |
| Instance-wide git hooks are stored centrally; example hooks are no longer written | 16 | Matters only for rollback: 15 needs its hooks regenerated (rollback step 6) |
| EXIF stripping of avatars removed | 16 | None |
| Repository links in rendered documents resolve from the repo root | 17 | None. No `.md` in this repo uses root-relative links |
| Action run webhook events deprecated | 17 | None. `homelab` has no webhooks |

## 0. Before the window

- No k3s phase in progress ([k3s-upgrade-1.35.md](k3s-upgrade-1.35.md) says not to merge during one).
- Not on a Sunday (kured reboots) and outside the backup window.
- Last night's Longhorn backups of `forgejo-db-pvc-17` and `forgejo-data-pvc` completed (Longhorn UI → Backup). They are the second rollback path.
- `git merge-tree --write-tree origin/main origin/pr/194` merges cleanly.

## 1. Suspend Flux

```bash
kubectl -n flux-system patch kustomization manifests --type merge -p '{"spec":{"suspend":true}}'
```

## 2. Merge the PR and pull it locally

Merge #194 in the Forgejo UI. With Flux suspended, nothing is applied yet. Then:

```bash
git switch main && git pull
```

## 3. Dump the database and record row counts

```bash
DUMP=~/forgejo-pre-v17-$(date +%Y%m%d-%H%M).dump
kubectl exec deploy/forgejo -c postgres -- pg_dump -U forgejo -Fc forgejo > "$DUMP"
kubectl exec -i deploy/forgejo -c postgres -- pg_restore --list < "$DUMP" | head -5   # must list the archive, not error
ls -lh "$DUMP"

COUNTS='SELECT (SELECT count(*) FROM "user"), (SELECT count(*) FROM repository), (SELECT count(*) FROM issue), (SELECT count(*) FROM action);'
kubectl exec deploy/forgejo -c postgres -- psql -U forgejo -d forgejo -Atc "$COUNTS" | tee ~/forgejo-counts-before.txt
```

## 4. Start Forgejo on 17

Apply the merged manifest directly. The kustomization's patches don't touch Forgejo, so this matches what Flux would apply.

```bash
kubectl apply -f manifests/productivity/forgejo.yaml
kubectl logs -f deploy/forgejo -c forgejo   # watch the migrations; Ctrl-C once it's listening
kubectl rollout status deploy/forgejo --timeout=6m
```

If the rollout fails, the migrations may have run partway. Go to rollback B, not A.

## 5. Check it works

- `curl -s https://git.rubiconetic.com/api/v1/version` reports `17.0.1`.
- Log in and open a repo.
- Push a throwaway branch, then delete it.
- Run `validate-manifests` by hand (Actions → Run workflow). This is also the first run of runner v13 against Forgejo 17.
- On `homelab`, Settings → Mirror settings → Synchronize now on the GitHub push mirror, and it shows no error.
- Synchronize one pull mirror, such as `michael/mattpocock-skills`.
- `kubectl logs deploy/forgejo -c forgejo | grep -i error` shows nothing new.

## 6. Resume Flux

```bash
kubectl -n flux-system patch kustomization manifests --type merge -p '{"spec":{"suspend":false}}'
kubectl -n flux-system annotate gitrepository flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite
kubectl -n flux-system get gitrepository,kustomization
```

Both should show `Ready=True` on the merge commit.

## Rollback

**A. Before step 4** (Forgejo has not run on 17). Nothing live has changed. Revert the merge commit on `main`, push it, and resume Flux (step 6).

**B. After step 4.** Keep Flux suspended. Changing the image alone won't work, because 15 refuses the migrated database, so the database is restored from the step 3 dump first. Forgejo stays scaled to zero during the restore: a Forgejo that started against the empty database would create a fresh schema in it.

1. Stop Forgejo:

   ```bash
   kubectl scale deploy/forgejo --replicas=0
   kubectl wait --for=delete pod -l app=forgejo --timeout=120s
   ```

2. Start Postgres on its own on the same volume:

   ```bash
   kubectl apply -f docs/runbooks/forgejo-db-rollback-pod.yaml
   kubectl wait --for=condition=Ready pod/forgejo-db-rollback --timeout=180s
   ```

3. Replace the database with the dump and compare counts:

   ```bash
   kubectl exec forgejo-db-rollback -- dropdb -U forgejo --force forgejo
   kubectl exec forgejo-db-rollback -- createdb -U forgejo -O forgejo forgejo
   kubectl exec -i forgejo-db-rollback -- pg_restore -U forgejo -d forgejo < "$DUMP" 2>&1 | tee ~/forgejo-rollback.log
   kubectl exec forgejo-db-rollback -- psql -U forgejo -d forgejo -Atc "$COUNTS" | diff - ~/forgejo-counts-before.txt && echo "counts match"
   ```

   Any `ERROR` in the log or a count mismatch means stop: restore `forgejo-db-pvc-17` from last night's Longhorn backup instead.

4. Remove the pod:

   ```bash
   kubectl delete pod forgejo-db-rollback
   ```

5. Revert the merge and start Forgejo on 15:

   ```bash
   git revert -m 1 <merge-commit>
   kubectl apply -f manifests/productivity/forgejo.yaml
   kubectl rollout status deploy/forgejo --timeout=6m
   ```

6. Regenerate the git hooks, since 16+ moved them:

   ```bash
   kubectl exec deploy/forgejo -c forgejo -- su git -c 'forgejo admin regenerate hooks --config /data/gitea/conf/app.ini'
   ```

7. Push a throwaway branch to confirm hooks work, then `git push` the revert and resume Flux (step 6).

Anything written to Forgejo while it ran on 17 is lost.

## Afterwards

- After about two weeks on 17, delete the local dump and `~/forgejo-counts-before.txt`.
- Optional: remove the example and duplicated hook files that 16 no longer needs, following the [upgrade guide](https://forgejo.org/docs/v17.0/admin/upgrade/).
- Plan the move to 18 before 28 January 2027, and re-check this table against its release notes.
- Record the date this ran here.
