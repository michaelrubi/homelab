# Runbook: Forgejo 17 → 18

Renovate will open a PR moving `codeberg.org/forgejo/forgejo` from `17.0.x` to `18.0.x` when 18 is published. Nothing in `renovate.json` automerges, so it waits for review. Forgejo runs its database migrations on first start, and they are one-way: 17 won't start on a database that 18 has migrated. A `pg_dump` taken just before the upgrade is the rollback.

This is the [Forgejo 15 → 17 runbook](forgejo-17-upgrade.md) with that run's lesson built in: suspend `flux-system` as well as `manifests`, or merging the PR deploys it before the dump.

## Timing

| | Date |
|---|---|
| 18.0 release | **14 January 2027** |
| 17.0 end of life | **28 January 2027** |
| 18.0 end of life | 29 April 2027 |
| 19.0 LTS release | 15 April 2027 (supported until 13 July 2028) |

Source: [Forgejo release schedule](https://forgejo.org/docs/next/admin/release-schedule/), read 2026-11-28. That leaves two weeks between 18's release and 17's end of life. The Saturdays in that window are **16 January** and **23 January 2027**.

18 isn't an LTS release either. Plan 18 → 19 LTS for late April 2027. 19 should then last until mid-2028. Forgejo stays on LTS from 19 on: see [decision 0001](../decisions/0001-forgejo-follows-lts.md).

## Breaking changes checked against this setup

**Not done yet: 18 isn't released.** On release day, read the 18.0 announcement on forgejo.org, the full release notes on Codeberg, and the [upgrade guide](https://forgejo.org/docs/next/admin/upgrade/). Check each breaking change against this setup and fill in the table.

| Change | Effect here |
|---|---|
| _(fill in from the 18.0 release notes)_ | |

Settings worth checking any change against:

- Postgres 17 runs as a sidecar in the same pod, at `127.0.0.1:5432`, on `forgejo-db-pvc-17`. Check the minimum Postgres version 18 requires.
- `ROOT_URL`, `INSTALL_LOCK` and `actions.ENABLED` are set through `FORGEJO__*` env vars. Everything else is in `/data/gitea/conf/app.ini` on `forgejo-data-pvc`.
- Forgejo Actions runs one runner (`runner-config` in `manifests/productivity/forgejo.yaml`). Check whether 18 needs a newer runner.
- `homelab` has a push mirror to GitHub, and there are about 15 pull mirrors.
- SSH is exposed on Service port 2222.
- The startup probe allows 5 minutes for migrations (`failureThreshold: 30` × 10 s).

## 0. Before the window

- Breaking-changes table above filled in.
- No k3s phase in progress ([k3s-upgrade-1.35.md](k3s-upgrade-1.35.md) says not to merge during one).
- **Not on a Sunday.** Kured reboots every node from 03:00 to 05:00 America/Phoenix, and `offsite-backup-check` runs at 07:00.
- Outside the backup window. Longhorn backs up to NFS at 20:00 Phoenix (03:00 UTC). `postgres-dump-standalone` runs at 04:00, and `offsite-backup` and `renovate` run at 05:00. Mid-morning to early evening is clear.
- Last night's Longhorn backups of `forgejo-db-pvc-17` and `forgejo-data-pvc` completed (Longhorn UI → Backup). They are the second rollback path.
- That morning's `offsite-backup` run succeeded: `kubectl get cronjob offsite-backup -o jsonpath='{.status.lastSuccessfulTime}'`.
- `git merge-tree --write-tree origin/main origin/<renovate-branch>` merges cleanly.

## 1. Suspend Flux

Suspend `flux-system` first. It applies `clusters/my-cluster/`, which contains the `manifests` Kustomization. Its next reconcile would remove a `suspend` set with `kubectl patch`, because that field isn't in git. That's how the 17 upgrade went live before its dump.

```bash
kubectl -n flux-system patch kustomization flux-system --type merge -p '{"spec":{"suspend":true}}'
kubectl -n flux-system patch kustomization manifests --type merge -p '{"spec":{"suspend":true}}'
kubectl -n flux-system get kustomization flux-system manifests -o jsonpath='{range .items[*]}{.metadata.name}={.spec.suspend}{"\n"}{end}'
```

Both must print `true`. `kubectl get kustomization` has no suspended column, so don't rely on its default output.

## 2. Merge the PR and pull it locally

Merge the Renovate PR in the Forgejo UI. With Flux suspended, nothing is applied yet. Then:

```bash
git switch main && git pull
grep -n 'forgejo/forgejo:' manifests/productivity/forgejo.yaml   # must show 18.0.x
```

## 3. Dump the database and record row counts

```bash
DUMP=~/forgejo-pre-v18-$(date +%Y%m%d-%H%M).dump
kubectl exec deploy/forgejo -c postgres -- pg_dump -U forgejo -Fc forgejo > "$DUMP"
kubectl exec -i deploy/forgejo -c postgres -- pg_restore --list < "$DUMP" | head -5   # must list the archive, not error
ls -lh "$DUMP"

COUNTS='SELECT (SELECT count(*) FROM "user"), (SELECT count(*) FROM repository), (SELECT count(*) FROM issue), (SELECT count(*) FROM action);'
kubectl exec deploy/forgejo -c postgres -- psql -U forgejo -d forgejo -Atc "$COUNTS" | tee ~/forgejo-counts-before.txt
```

Run every step in the same persistent shell. Rollback B uses `$DUMP` and `$COUNTS`. A shell that starts fresh for each command, such as `!` commands in Claude Code, loses them.

**Don't push to Forgejo** between this step and step 6. A rollback restores the database to this point, and anything written after it is lost.

## 4. Start Forgejo on 18

Apply the merged manifest directly. The kustomization's patches don't touch Forgejo, so this matches what Flux would apply.

```bash
kubectl apply -f manifests/productivity/forgejo.yaml
kubectl logs -f deploy/forgejo -c forgejo   # watch the migrations; Ctrl-C once it's listening
kubectl rollout status deploy/forgejo --timeout=6m
```

Downtime runs from here until the pod is ready, a few minutes at most. If the rollout fails, the migrations may have run partway. Go to rollback B, not A.

## 5. Check it works

- `curl -s https://git.rubiconetic.com/api/v1/version` reports `18.0.x`.
- Log in and open a repo.
- Push a throwaway branch over HTTPS and over SSH (port 2222), then delete it.
- Run `validate-manifests` by hand (Actions → Run workflow) to confirm the runner works with 18.
- On `homelab`, Settings → Mirror settings → Synchronize now on the GitHub push mirror, and it shows no error.
- Synchronize one pull mirror, such as `michael/mattpocock-skills`.
- `kubectl logs deploy/forgejo -c forgejo | grep -iE 'error|fatal'` shows nothing new. The two `package_cleanup_rule` BIGINT/INTEGER warnings date from 17 and are harmless.

## 6. Resume Flux

```bash
kubectl -n flux-system patch kustomization manifests --type merge -p '{"spec":{"suspend":false}}'
kubectl -n flux-system patch kustomization flux-system --type merge -p '{"spec":{"suspend":false}}'
kubectl -n flux-system annotate gitrepository flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite
kubectl -n flux-system get gitrepository,kustomization
```

Both should show `Ready=True` on the merge commit.

## Rollback

**A. Before step 4** (Forgejo has not run on 18). Nothing live has changed. Revert the merge commit on `main`, push it, and resume Flux (step 6).

**B. After step 4.** Keep Flux suspended. Changing the image alone won't work, because 17 refuses the migrated database. Restore the database from the step 3 dump first. Keep Forgejo scaled to zero during the restore: a Forgejo that started against the empty database would create a fresh schema in it.

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

5. Revert the merge and start Forgejo on 17:

   ```bash
   git revert -m 1 <merge-commit>
   kubectl apply -f manifests/productivity/forgejo.yaml
   kubectl rollout status deploy/forgejo --timeout=6m
   ```

6. If the 18 release notes say it changes how git hooks are stored (as 16 did), regenerate them:

   ```bash
   kubectl exec deploy/forgejo -c forgejo -- su git -c 'forgejo admin regenerate hooks --config /data/gitea/conf/app.ini'
   ```

7. Push a throwaway branch to confirm pushes and hooks work, then `git push` the revert and resume Flux (step 6).

Anything written to Forgejo while it ran on 18 is lost.

## Afterwards

- After about two weeks on 18, delete the dump and `~/forgejo-counts-before.txt`.
- Add a "Run on <date>" section here with what happened.
- Plan 18 → 19 LTS for after 15 April 2027, before 18's end of life on 29 April 2027.
