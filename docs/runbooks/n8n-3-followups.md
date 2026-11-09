# Runbook: n8n 3.x follow-ups

n8n moved to 3.1.0 on 2026-11-09 (#196, prepared in #202). Its first start logged three things to fix:

```text
Postgres 16 is outside the supported range and receives compatibility support only. Upgrade to Postgres 17 or newer.
Failed to start Python task runner in internal mode. because Python 3 is missing from this system.
There are deprecations related to your n8n setup:
 - WEBHOOK_URL -> Use N8N_WEBHOOK_URL instead
 - N8N_RUNNERS_MODE -> Internal task runner mode is deprecated
```

| Part | Change | Door | Downtime |
|---|---|---|---|
| A | External task runners (adds Python) and `N8N_WEBHOOK_URL`, as one PR | Two-way: revert the PR | One n8n restart |
| B | n8n's Postgres 16 → 17, by dump and restore into a new volume | Two-way until the old volume is deleted | About 10 minutes of n8n |

Do A first. It's small, and it can be reverted. B is a maintenance window. Neither depends on the other.

**Avoid k3s phases.** Don't run either part during a phase of [k3s-upgrade-1.35.md](k3s-upgrade-1.35.md), which forbids merging to `main` while one is in progress. As of 2026-11-09, phase 1b (Longhorn) and phase 2 (k3s 1.35) are planned for 9–10 November.

## A. External task runners, `N8N_WEBHOOK_URL` and proxy hops

Today the JavaScript runner runs inside the n8n container ("internal mode"), and the n8n image has no Python, so Python Code nodes can't run. The `n8nio/runners` image holds the launcher plus the JavaScript and Python runners. It runs as a sidecar in the n8n pod and connects to n8n's task broker over `localhost`.

```diff
 n8n-deployment (pod)
   n8n                    docker.n8n.io/n8nio/n8n:3.1.0
-    WEBHOOK_URL            ← n8n-secrets/N8N_URL
+    N8N_WEBHOOK_URL        ← n8n-secrets/N8N_URL
+    N8N_RUNNERS_MODE       = external
+    N8N_RUNNERS_AUTH_TOKEN ← n8n-secrets/N8N_RUNNERS_AUTH_TOKEN
+    N8N_PROXY_HOPS         = 1
     N8N_RUNNERS_TASK_TIMEOUT = 300           (from #202, unchanged)
+  runners                n8nio/runners:3.1.0  (tag must equal n8n's)
+    N8N_RUNNERS_TASK_BROKER_URI = http://127.0.0.1:5679
+    N8N_RUNNERS_AUTH_TOKEN ← n8n-secrets/N8N_RUNNERS_AUTH_TOKEN
```

### 1. Add the shared token

Change secrets only with `sops edit`, never by re-encrypting a plaintext copy ([post-mortem](../postmortems/2026-09-secrets-wipe-and-stale-reencrypt.md)).

```bash
openssl rand -hex 32   # copy the output
sops edit manifests/secrets/secrets.sops.yaml
```

In the `n8n-secrets` document, add `N8N_RUNNERS_AUTH_TOKEN: <the value>` under `stringData`. Save, then confirm only that document changed: `git diff --stat` shows the one file, and `sops -d manifests/secrets/secrets.sops.yaml | grep -c N8N_RUNNERS_AUTH_TOKEN` prints `1`.

### 2. Change `manifests/automation/n8n.yaml`

- Rename `WEBHOOK_URL` to `N8N_WEBHOOK_URL`. It keeps the same `secretKeyRef`.
- Add `N8N_PROXY_HOPS=1`. Traffic arrives through cloudflared with `X-Forwarded-For` set, and without this Express doesn't trust the header. n8n 3.1.0 logs `ERR_ERL_UNEXPECTED_X_FORWARDED_FOR` on every request, and its rate limiter sees cloudflared's address for every client, so all clients share one limit.
- Add `N8N_RUNNERS_MODE=external` and `N8N_RUNNERS_AUTH_TOKEN` from `n8n-secrets`.
- Leave `N8N_RUNNERS_BROKER_LISTEN_ADDRESS` unset. Its default is `127.0.0.1`, and a sidecar shares the pod's network, so the broker needs no wider exposure and no NetworkPolicy change.
- Add the `runners` container:
  - Image `n8nio/runners:3.1.0`. Docker Hub has this tag; check `docker.n8n.io/n8nio/runners` has it too before using that registry instead.
  - `N8N_RUNNERS_TASK_BROKER_URI=http://127.0.0.1:5679` and the same `N8N_RUNNERS_AUTH_TOKEN`. Use the IP: the broker listens on IPv4 only, and `localhost` can resolve to `::1` first.
  - Requests of `memory: 128Mi`, `cpu: 50m`, and a `512Mi` limit to start. Measure it after a week and adjust, as was done for n8n.
  - Move `runAsUser: 1000` and `runAsGroup: 1000` from the pod to the n8n container, and keep `fsGroup` on the pod. The runners image runs as its own named user, `runner`, and a pod-level UID would override it.

The deployment's `reloader.stakater.com/auto` annotation restarts n8n when `n8n-secrets` changes, so the secret and the manifest should land in the same PR.

### 3. Keep the two images in step with Renovate

The runners tag must always equal the n8n tag. Add a group rule to `renovate.json` so one PR moves both:

```json
{
  "description": "n8n and its task runners must run the same version.",
  "matchPackageNames": ["docker.n8n.io/n8nio/n8n", "n8nio/runners"],
  "groupName": "n8n"
}
```

### 4. Merge and verify

n8n isn't Flux's source, so there's nothing to suspend. Merge, and Flux restarts the pod with both containers.

```bash
kubectl get pod -l app=n8n                      # 2/2 Running
kubectl logs deploy/n8n-deployment -c n8n | grep -iE 'runner|deprecat|python'
kubectl logs deploy/n8n-deployment -c runners --tail=30
```

- The n8n log no longer mentions Python missing, internal mode, `WEBHOOK_URL` or `ERR_ERL_UNEXPECTED_X_FORWARDED_FOR`, and shows a runner registering.
- A JavaScript Code node runs: open any workflow with one and run it.
- A Python Code node runs: a new test workflow with a Code node set to Python, returning `[{"json": {"ok": True}}]`.
- A production webhook still answers on the public URL, such as the booking form.

**Rollback:** revert the PR. n8n goes back to internal mode with no data involved.

## B. n8n's Postgres 16 → 17

The `postgres` Deployment in `manifests/automation/n8n-pg.yaml` serves only n8n's database (`n8n`). Postgres can't start a new major version on an old data directory, so this is a dump and restore into a **new** volume, `postgres-pvc-17`. The old `postgres-pvc` stays untouched, and it is the rollback. This follows [forgejo-postgres-upgrade.md](forgejo-postgres-upgrade.md).

- **Version:** 17, not 18. n8n asks for 17 or newer, 17 matches Forgejo's database, and the `postgres:18` image changes its data directory layout.
- **Image:** `postgres:17`, not alpine. The Deployment's comment explains the glibc collation reason, and the dump carries glibc locale names.
- **Downtime:** n8n is down from step 3 to step 9. Webhooks that arrive in that window fail.
- **One terminal:** run every step in the same persistent shell, because later steps reuse `$DUMP` and `$COUNTS`.

### The PR

One PR, merged in step 2 while Flux is suspended:

```diff
 manifests/automation/n8n-pg.yaml
+  PersistentVolumeClaim postgres-pvc-17        (same spec as postgres-pvc)
   Deployment postgres
-    image: postgres:16
+    image: postgres:17
-    claimName: postgres-pvc
+    claimName: postgres-pvc-17
 manifests/infrastructure/postgres-dump.yaml
-  image: postgres:16-alpine     # pg_dumpall 16 refuses to dump a 17 server
+  image: postgres:17-alpine
```

Keep the `postgres-pvc` object in the file, so Flux doesn't prune the rollback volume. Also update the comment above the image so it records the move to 17.

### 0. Before the window

- Pick a weekday evening, outside the 03:00–05:00 Phoenix backups, and outside any k3s phase.
- Last night's Longhorn backup of `postgres-pvc` completed (Longhorn UI → Backup).
- Last night's `postgres-dump-standalone` job succeeded.

### 1. Suspend Flux

`flux-system` first. Suspending only `manifests` doesn't hold: `flux-system` re-applies it and clears the suspend.

```bash
kubectl -n flux-system patch kustomization flux-system --type merge -p '{"spec":{"suspend":true}}'
kubectl -n flux-system patch kustomization manifests --type merge -p '{"spec":{"suspend":true}}'
kubectl -n flux-system get kustomization flux-system manifests -o jsonpath='{range .items[*]}{.metadata.name}={.spec.suspend}{"\n"}{end}'
```

Both must print `true`.

### 2. Merge the PR and pull it locally

Merge it in the Forgejo UI. With Flux suspended, nothing is applied. Then `git switch main && git pull`.

### 3. Stop n8n

Nothing must write to the database after the dump.

```bash
kubectl scale deploy/n8n-deployment --replicas=0
kubectl wait --for=delete pod -l app=n8n --timeout=120s
```

### 4. Dump the 16 cluster and record row counts

```bash
DUMP=~/n8n-pg16-$(date +%Y%m%d-%H%M).sql.gz
kubectl exec deploy/postgres -- sh -c 'pg_dumpall -U "$POSTGRES_USER"' | gzip > "$DUMP"
gunzip -c "$DUMP" | tail -3   # must end with "PostgreSQL database cluster dump complete"
ls -lh "$DUMP"

COUNTS='SELECT (SELECT count(*) FROM workflow_entity), (SELECT count(*) FROM credentials_entity), (SELECT count(*) FROM execution_entity), (SELECT count(*) FROM installed_packages);'
kubectl exec deploy/postgres -- sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc "$0"' "$COUNTS" | tee ~/n8n-counts-before.txt
```

`workflow_entity` includes archived workflows, so this count is higher than the editor's list: 194 against 124 on 2026-11-09. What matters is that step 7 matches it exactly.

### 5. Stop Postgres 16

```bash
kubectl scale deploy/postgres --replicas=0
kubectl wait --for=delete pod -l app=postgres --timeout=120s
```

### 6. Create the 17 volume and restore into it

```bash
kubectl apply -f docs/runbooks/n8n-pg17-restore-pod.yaml
kubectl wait --for=condition=Ready pod/n8n-pg17-restore --timeout=180s
gunzip -c "$DUMP" | kubectl exec -i n8n-pg17-restore -- sh -c 'psql -U "$POSTGRES_USER" -d postgres -q' 2>&1 | tee ~/n8n-restore.log
```

One error is expected: the role already exists, because the restore pod's initdb created it. Any other `ERROR` line means stop and go to rollback A.

### 7. Verify

```bash
kubectl exec n8n-pg17-restore -- sh -c 'psql -U "$POSTGRES_USER" -d n8n -Atc "$0"' "$COUNTS" | diff - ~/n8n-counts-before.txt && echo "counts match"
kubectl exec n8n-pg17-restore -- sh -c 'psql -U "$POSTGRES_USER" -d n8n -Atc "SHOW server_version;"'
```

If `POSTGRES_DB` in `n8n-db-secrets` isn't `n8n`, use its value in place of `-d n8n`.

### 8. Remove the restore pod (keep the volume)

```bash
kubectl delete pod n8n-pg17-restore
```

### 9. Start Postgres 17, then n8n

Apply the merged manifests directly. This also restores n8n's `replicas: 1`.

```bash
kubectl apply -f manifests/automation/n8n-pg.yaml
kubectl rollout status deploy/postgres --timeout=5m
kubectl apply -f manifests/automation/n8n.yaml -f manifests/infrastructure/postgres-dump.yaml
kubectl rollout status deploy/n8n-deployment --timeout=5m
```

### 10. Check it works

- The n8n log no longer warns about Postgres 16: `kubectl logs deploy/n8n-deployment -c n8n | grep -i postgres`.
- The editor lists every workflow, and the active ones are still active.
- Settings → Community nodes shows no load errors.
- A production webhook answers, and a scheduled workflow runs on time.
- pgweb connects.
- Start the dump job by hand and confirm it completes: `kubectl create job --from=cronjob/postgres-dump-standalone pg-dump-manual-$(date +%s)`.

### 11. Resume Flux

`manifests` first, then `flux-system`:

```bash
kubectl -n flux-system patch kustomization manifests --type merge -p '{"spec":{"suspend":false}}'
kubectl -n flux-system patch kustomization flux-system --type merge -p '{"spec":{"suspend":false}}'
kubectl -n flux-system annotate gitrepository flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite
kubectl -n flux-system get gitrepository,kustomization
```

All should show `Ready=True` on the merge commit.

### Rollback

**A. Before step 9** (nothing has run on 17). The old volume is untouched:

```bash
kubectl delete pod n8n-pg17-restore --ignore-not-found
kubectl scale deploy/postgres --replicas=1
kubectl rollout status deploy/postgres
kubectl scale deploy/n8n-deployment --replicas=1
```

Then revert the merge commit on `main` and resume Flux (step 11). Delete `postgres-pvc-17` if you won't retry soon.

**B. After step 9.** The old Deployment spec points at `postgres-pvc`, which hasn't changed:

```bash
git revert -m 1 <merge-commit>
kubectl scale deploy/n8n-deployment --replicas=0
kubectl apply -f manifests/automation/n8n-pg.yaml -f manifests/infrastructure/postgres-dump.yaml
kubectl rollout status deploy/postgres
kubectl apply -f manifests/automation/n8n.yaml
git push
```

Then resume Flux (step 11). Anything n8n wrote while it ran on 17 is lost.

### Afterwards

- After about two weeks on 17, remove the `postgres-pvc` object from `n8n-pg.yaml` in its own PR. Flux prunes the volume. Delete the local dump at the same time.

## Run on 2026-11-09

Both parts ran the same day, a few hours after #196 moved n8n to 3.1.0.

**Part A** (#206) merged at about 10:49 Phoenix. The pod came up `2/2`, and n8n registered `launcher-javascript` and `launcher-python`.
- A manual run of a JavaScript → Python Code node test succeeded (execution `239737`).
- The same nodes behind a GET webhook returned HTTP 200 through the public URL (`239738`, `239739`).
- After those requests, the log had no Python-missing, deprecation or `ERR_ERL_UNEXPECTED_X_FORWARDED_FOR` lines.
- The token was added with `sops edit`. A decrypted comparison with `main` showed all 14 documents intact, with `n8n-secrets` / `N8N_RUNNERS_AUTH_TOKEN` as the only difference.
- The test workflow, "My workflow 68" (`7IJ9vLiYZFH5vWR0`), was left published at `/webhook/runner-test-c66f735c7408` as a runner health check.

**Part B** (#207) ran from about 10:58 to 11:10 Phoenix, a weekday morning rather than an evening. n8n was down from about 11:00 to 11:05: the dump file is stamped 11:00, and the first webhook on 17 ran at 11:05.
- Flux was suspended with `flux-system` first, and both read `true` throughout.
- The 16 dump was `~/n8n-pg16-20261109-1100.sql.gz`, 36 MB. Counts were `194|90|10032|12` (workflows, credentials, executions, packages).
- The restore had one `ERROR`, the expected `role "n8n" already exists`. The counts matched on 17, and the server reported `17.7 (Debian 17.7-3.pgdg13+1)`.
- After the restore, the log had no Postgres 16 warning.
  - The runner test webhook answered.
  - All 124 workflows were listed.
  - New execution IDs continued from the restored sequence (`239742`).
  - Community nodes and pgweb worked.
- A manual `postgres-dump-standalone` run on `postgres:17-alpine` wrote a 34.5 MB dump. It spent about a minute in its `pg_isready` loop before connecting to the new pod.
- Flux resumed `manifests` first, then `flux-system`, and both were `Ready` on `c77673d`.

`kubectl apply` in step 9 printed `missing the kubectl.kubernetes.io/last-applied-configuration annotation` for each object Flux had created. That's expected: Flux takes them back on its next reconcile.

## Also due

- Around 2026-11-17: delete `~/.n8n/nodes.bak-20261103` on `n8n-pvc`.
- Around 2026-11-23: delete `~/n8n-pre-v3-20261109-0958.dump`, the dump taken before #196, once 3.x has run cleanly for two weeks.
- Around 2026-11-23: the `postgres-pvc` removal PR from part B's Afterwards, then delete `~/n8n-pg16-20261109-1100.sql.gz` and `~/n8n-counts-before.txt`.
- Check why the newest `postgres-temporal-*` dump on the NFS share is from 2026-11-03.
