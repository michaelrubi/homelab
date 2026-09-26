# PLAN: Forgejo runner — real job images and Docker access

**Status: ready to execute. Written 2026-09-26 after live verification of the
cluster. Intended to be executed step-by-step by a coding agent — every edit,
command, and pass criterion is spelled out. Stop and report at the first
unexpected result.**

**Supersedes the Gemini-proposed "Forgejo Runners with DinD on K3s" prompt.
That prompt re-implements things this cluster already has; see "Why this plan
exists".**

## Why this plan exists

The runner is **not broken**. Verified live on 2026-09-26:

| Check | Result |
|---|---|
| `forgejo-runner-0` pod | 2/2 Running 4d14h |
| Registration | id 272, `/data/runner` on PVC, re-registration correctly skipped |
| Daemon | v12.8.2, polling, "declared successfully" |
| Real jobs | `validate-manifests` tasks 68–77 executed on DinD; runs 780–782 green |
| DinD | 29.2.1, pulls images, runs job containers, per-job networks cleaned up |

The old `simple-test` / `test-kaniko` cancelled runs (IDs 191–201) are months
old — from the pre-token-fix crash era. They are not evidence of a current
problem.

What is actually missing is job quality. Three real gaps, one workflow fix:

1. **Job images are `node:22-alpine`** (both `ubuntu-latest` and `docker`
   labels). It has no `git`, `curl`, or `tar`, so `actions/checkout` fails
   and `validate-manifests.yml` has to `apk add` its own toolchain. Any
   GitHub-style workflow breaks the same way.
2. **Job containers cannot reach Docker.** Nothing wires the DinD daemon
   into job containers, so `docker build` jobs fail with "Cannot connect to
   the Docker daemon".
3. **DinD image storage is ephemeral.** `/var/lib/docker` is not mounted at
   all — every pod restart wipes every cached image.
4. **`validate-manifests.yml` assumes Alpine.** Its `apk add` line breaks
   the moment job images become Ubuntu-based (catthehacker), so it must be
   fixed in the same effort.

What the Gemini prompt got right: richer label images (`catthehacker`), and
generally the DinD-sidecar + StatefulSet shape. What it got wrong for this
cluster: a `forgejo` namespace and `forgejo-http` service that don't exist
(ours: `default` / `forgejo-service.default.svc.cluster.local:3000`), a
markdown-mangled URL, `local-path` storage (we're Longhorn), TLS/CA bundle
work (all internal traffic is plain HTTP; no internal CA), `kubectl create
secret` (this repo is Flux+SOPS GitOps), `runner:latest` (repo pins `:12`),
and `container.network: host` (bridge networking is proven working here).

## Ground truth (verified 2026-09-26 — do not re-litigate)

- Namespace is `default`. Forgejo Service: `forgejo-service.default.svc.cluster.local:3000`.
  This URL is also Flux's own git source — do not change it anywhere.
- Runner image is pinned `data.forgejo.org/forgejo/runner:12`. Keep it pinned.
- Registration file is `/data/runner` (no dot). Registration is idempotent
  (checks `[ ! -f /data/runner ]`). The PVC is `runner-data` via
  `volumeClaimTemplates`, storageClassName `longhorn`. All correct; leave alone.
- The runner config is mounted at `/config/config.yml` via a **subPath**
  ConfigMap mount. SubPath mounts never hot-reload — only a new pod picks up
  ConfigMap changes.
- Runner v12 reads job labels from `config.yml` (`runner.labels`) — the
  registration-file labels are only a fallback. So labels are changed by
  config + pod restart, **no re-registration needed** (official docs:
  https://forgejo.org/docs/next/admin/actions/configuration/#choosing-labels).
- The official Docker-in-Docker access pattern for exactly our architecture
  (runner + dind sidecar sharing a pod netns, `docker_host: tcp://...`):
  https://forgejo.org/docs/next/admin/actions/docker-access/#docker-in-docker
  — inject `DOCKER_HOST` into job containers via `runner.envs` plus a
  `--add-host=...:host-gateway` in `container.options`.
- Verified in the live DinD container: `dockerd` listens on
  `unix:///var/run/docker.sock` AND `tcp://0.0.0.0:2375` (pod-IP reachable),
  TLS disabled. The `docker:dind` entrypoint only injects those default
  `--host` args when no explicit command is given, so if we add a `command:`,
  we must pass both hosts ourselves.
- Pushing to Forgejo's registry at `http://forgejo-service.default...:3000`
  is plain HTTP, so DinD needs `--insecure-registry=forgejo-service.default.svc.cluster.local:3000`
  for Tier 3 `docker push` to work.
- Job containers resolve cluster DNS through DinD (proven: today's
  `checkout@v4` clones from the internal Service URL on bridge networks).
- `michael/homelab` repo is public → run statuses are readable
  unauthenticated via the in-cluster API (used in verification steps below).
- The repo pre-commit hook only audits `manifests/automation/n8n.yaml`; it
  will not interact with these commits.

## Rules for the executor

- **Do not touch:** namespace, Service names/URLs, storage classes, PVCs,
  image pins, `/data/runner` filename, `forgejo-secrets` / SOPS plumbing,
  `container.network`, anything TLS/CA related. Never run `kubectl apply` —
  this repo is Flux GitOps; changes land via `git push` to `main`.
- The two commits must be made **in the given order** (Phase 1 → wait for
  rollout → Phase 3). Committing everything at once causes one red
  `validate` run (new no-`apk` workflow executed on the old Alpine image)
  that looks like a failure but is just the label switch lagging the push.
- Every "Expected:" block is the pass criterion. Stop and report on any
  mismatch. Do not improvise remediations beyond the two documented
  fallbacks.

## Phase 1 — Commit A: runner manifest changes

File: `manifests/productivity/forgejo.yaml`. Four edits.

### Edit 1 — ConfigMap `runner-config` (section `# 5. Runner Config`)

Current `data:` block:

```yaml
data:
  config.yml: |
    log:
      level: info
    runner:
      file: /data/runner
      capacity: 1
      timeout: 3h
      envs:
        GITHUB_SERVER_URL: "http://forgejo-service.default.svc.cluster.local:3000"
    cache:
      enabled: true
      dir: /data/cache
    container:
      docker_host: tcp://localhost:2375
```

Replace with (adds `DOCKER_HOST` env for job containers, adds `runner.labels`
with real job images, adds the `host-gateway` alias for job containers):

```yaml
data:
  config.yml: |
    log:
      level: info
    runner:
      file: /data/runner
      capacity: 1
      timeout: 3h
      envs:
        GITHUB_SERVER_URL: "http://forgejo-service.default.svc.cluster.local:3000"
        DOCKER_HOST: tcp://docker.internal:2375
      # Labels come from config (registration-file labels are a fallback
      # only). act-22.04 is the GitHub-runner-compatible image: git, curl,
      # node, docker CLI included. Docs:
      # https://forgejo.org/docs/next/admin/actions/configuration/#choosing-labels
      labels:
        - "ubuntu-latest:docker://ghcr.io/catthehacker/ubuntu:act-22.04"
        - "docker:docker://ghcr.io/catthehacker/ubuntu:act-22.04"
    cache:
      enabled: true
      dir: /data/cache
    container:
      docker_host: tcp://localhost:2375
      # Official DinD access pattern: job containers reach the dind daemon
      # via DOCKER_HOST above; host-gateway resolves to the pod netns where
      # dockerd listens on 0.0.0.0:2375.
      # https://forgejo.org/docs/next/admin/actions/docker-access/#docker-in-docker
      options: "--add-host=docker.internal:host-gateway"
```

### Edit 2 — registration labels (inside the runner container command, `# 6. Runner` section)

Current line (single line inside the `command:` block):

```sh
                forgejo-runner register --no-interactive --config /config/config.yml --name $FORGEJO_RUNNER_NAME --instance $FORGEJO_INSTANCE_URL --token $FORGEJO_RUNNER_REGISTRATION_TOKEN --labels docker:docker://node:22-alpine,ubuntu-latest:docker://node:22-alpine,kaniko:docker://gcr.io/kaniko-project/executor:debug
```

Replace with (keep in sync with Edit 1 in case the PVC is ever recreated;
`kaniko` is dropped — nothing uses it, and docker builds via the socket
supersede it):

```sh
                forgejo-runner register --no-interactive --config /config/config.yml --name $FORGEJO_RUNNER_NAME --instance $FORGEJO_INSTANCE_URL --token $FORGEJO_RUNNER_REGISTRATION_TOKEN --labels docker:docker://ghcr.io/catthehacker/ubuntu:act-22.04,ubuntu-latest:docker://ghcr.io/catthehacker/ubuntu:act-22.04
```

### Edit 3 — DinD container (section `# 2. Docker-in-Docker (The Builder)`)

Current block:

```yaml
        # 2. Docker-in-Docker (The Builder)
        - name: docker
          image: docker:dind
          # dind builds are bursty: a low request keeps it off the
          # scheduler's critical path, the limit stops a runaway build
          # from taking the node down with it.
          resources:
            requests:
              memory: "256Mi"
              cpu: "100m"
            limits:
              memory: "2Gi"
          securityContext:
            privileged: true
          env:
            - name: DOCKER_TLS_CERTDIR
              value: ""
            - name: DOCKER_HOST
              value: tcp://localhost:2375
          volumeMounts:
            - name: runner-data
              mountPath: /data
```

Replace with (adds explicit dockerd args — the dind entrypoint injects
default `--host`s only when no command is given, so both hosts must be
restated; adds the insecure-registry entry Tier 3 needs; persists
`/var/lib/docker` on an emptyDir so pod restarts don't wipe image cache):

```yaml
        # 2. Docker-in-Docker (The Builder)
        - name: docker
          image: docker:dind
          # dind builds are bursty: a low request keeps it off the
          # scheduler's critical path, the limit stops a runaway build
          # from taking the node down with it.
          resources:
            requests:
              memory: "256Mi"
              cpu: "100m"
            limits:
              memory: "2Gi"
          securityContext:
            privileged: true
          # Explicit hosts replace the entrypoint defaults (which only
          # apply when no command is set). insecure-registry is required
          # to push to the plain-HTTP internal Forgejo registry in Tier 3.
          command:
            - dockerd
            - --host=unix:///var/run/docker.sock
            - --host=tcp://0.0.0.0:2375
            - --tls=false
            - --insecure-registry=forgejo-service.default.svc.cluster.local:3000
          env:
            - name: DOCKER_TLS_CERTDIR
              value: ""
            - name: DOCKER_HOST
              value: tcp://localhost:2375
          volumeMounts:
            - name: runner-data
              mountPath: /data
            - name: dind-storage
              mountPath: /var/lib/docker
```

### Edit 4 — StatefulSet volumes (the pod-level `volumes:` list)

Current:

```yaml
      volumes:
        - name: config
          configMap:
            name: runner-config
```

Replace with:

```yaml
      volumes:
        - name: config
          configMap:
            name: runner-config
        - name: dind-storage
          emptyDir: {}
```

### Commit and push A

```bash
git add manifests/productivity/forgejo.yaml
git commit -m "feat(forgejo): real job images and docker access for runner jobs"
git push
```

## Phase 2 — Apply, restart, verify

Flux reconciles within ~60s of the push.

1. Wait for the StatefulSet rollout (the pod template changed, so a
   rolling restart happens automatically):

   ```bash
   kubectl -n default rollout status statefulset/forgejo-runner --timeout=180s
   ```

   Expected: `statefulset "forgejo-runner" successfully rolled out`.
   The pod is `forgejo-runner-0`, 2/2 Running. (If it looks stuck, check
   `kubectl -n default describe pod forgejo-runner-0` — most likely cause
   would be a dockerd flag typo: it would crash-loop the `docker` container
   and show in `kubectl logs forgejo-runner-0 -c docker`.)

2. Confirm the new pod is running the new config (it is a fresh pod, so the
   subPath ConfigMap mount has current content):

   ```bash
   kubectl exec forgejo-runner-0 -c runner -- cat /config/config.yml
   ```

   Expected: shows the `runner.labels` entries with
   `ghcr.io/catthehacker/ubuntu:act-22.04`, the `DOCKER_HOST` env, and the
   `options` line.

3. Confirm the daemon declares the new labels and skips registration:

   ```bash
   kubectl logs forgejo-runner-0 -c runner --tail=20
   ```

   Expected: `Runner already registered. Skipping registration.`, then
   `declared successfully` with labels `[docker ubuntu-latest]` — and
   **no** `kaniko`.

4. Confirm dockerd came up with the insecure registry:

   ```bash
   kubectl exec forgejo-runner-0 -c docker -- docker info 2>/dev/null | grep -A2 'Insecure Registries'
   ```

   Expected: lists `forgejo-service.default.svc.cluster.local:3000`.

5. Confirm the push's own validate run stayed green (it ran on the old
   labels because the rollout lags the push):

   ```bash
   kubectl exec deploy/forgejo -c forgejo -- curl -s "http://localhost:3000/api/v1/repos/michael/homelab/actions/runs?limit=1"
   ```

   Expected: latest run `validate-manifests.yml` with `"status":"success"`.

### Fallback B — only if step 2/3 shows the daemon still using old labels

(Not expected — v12 documented behavior is config labels win. Only apply if
the log still declares node:22-alpine-mapped labels, e.g. you see a
registration happening with old images or the Forgejo UI shows old labels on
a fresh job.)

```bash
kubectl exec forgejo-runner-0 -c runner -- rm /data/runner
kubectl delete pod forgejo-runner-0
```

The pod re-registers with the Edit 2 labels. This creates a **new** runner
entry in Forgejo; the old one (id 272) goes offline. After verification,
delete the dead entry: Forgejo UI → Site Administration → Actions →
Runners → remove the offline `forgejo-runner-0`.

## Phase 3 — Commit B: workflow fix + smoke tests

Only after Phase 2 passes.

### Edit 5 — `.forgejo/workflows/validate-manifests.yml`

The job image is now Ubuntu-based; `apk` no longer exists. Remove the
`apk` line from the "Install tooling" step (curl/tar/git ship with
catthehacker):

Current:

```yaml
      - name: Install tooling
        run: |
          set -eu
          apk add --no-cache curl tar git
          curl -sSL "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv${KUSTOMIZE_VERSION}/kustomize_v${KUSTOMIZE_VERSION}_linux_amd64.tar.gz" | tar -xz -C /usr/local/bin kustomize
```

Replace with:

```yaml
      - name: Install tooling
        run: |
          set -eu
          curl -sSL "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv${KUSTOMIZE_VERSION}/kustomize_v${KUSTOMIZE_VERSION}_linux_amd64.tar.gz" | tar -xz -C /usr/local/bin kustomize
```

(Leave the kubeconform download and everything after it unchanged.)

### Edit 6 — `.forgejo/workflows/simple-test.yml` — prove the image switch

Replace the file's step body so the run itself proves which image served it:

```yaml
name: simple-test

on:
  workflow_dispatch:

jobs:
  hello:
    runs-on: ubuntu-latest
    steps:
      - run: |
          echo "Hello from Forgejo Actions!"
          grep PRETTY_NAME /etc/os-release
```

Expected in the job log: `PRETTY_NAME="Ubuntu 22.04.x LTS"`. If it says
Alpine, the label switch didn't take effect — go to Fallback B.

### New file — `.forgejo/workflows/test-docker.yml` (Tier 2)

```yaml
name: test-docker

on:
  workflow_dispatch:

jobs:
  test:
    runs-on: docker
    steps:
      - name: Docker daemon reachable from inside the job container
        run: |
          docker version
          docker run --rm alpine:3.20 sh -c 'echo "docker run works: $(uname -a)"'
```

### New file — `.forgejo/workflows/test-build-push.yml` (Tier 3)

```yaml
name: test-build-push

on:
  workflow_dispatch:

jobs:
  build:
    runs-on: docker
    steps:
      - uses: actions/checkout@v4
      - name: Create throwaway Dockerfile
        run: |
          printf 'FROM alpine:3.20\nRUN echo "built by forgejo runner" > /built.txt\n' > Dockerfile
      - name: Login to Forgejo container registry
        run: |
          echo "${{ secrets.FORGEJO_TOKEN }}" | docker login forgejo-service.default.svc.cluster.local:3000 -u "${{ secrets.FORGEJO_USERNAME }}" --password-stdin
      - name: Build and push
        run: |
          docker build -t forgejo-service.default.svc.cluster.local:3000/${{ gitea.repository }}:ci-smoke .
          docker push forgejo-service.default.svc.cluster.local:3000/${{ gitea.repository }}:ci-smoke
```

### Commit and push B

```bash
git add .forgejo/workflows/
git commit -m "feat(ci): fix validate for ubuntu job image, add runner smoke tests"
git push
```

## Phase 4 — Verification ladder

Requires the user (or any account with repo access) to click
**Actions → \<workflow\> → Run workflow** in the Forgejo web UI for each
dispatch-only workflow. If nobody is at the UI, Tier 1 can be confirmed
passively: the next Renovate PR (~12:01 daily) or any push triggers
`validate-manifests` on the new image.

The executor verifies outcomes without UI access via:

```bash
kubectl exec deploy/forgejo -c forgejo -- curl -s \
  "http://localhost:3000/api/v1/repos/michael/homelab/actions/runs?limit=5"
```

**Tier 1 — `simple-test` on `ubuntu-latest`.**
Pass: run status `success`; job log shows `PRETTY_NAME="Ubuntu 22.04.x LTS"`.
Note: the first run after the rollout pulls ~1.4 GB (catthehacker) into
DinD — allow several minutes before declaring failure; watch progress with
`kubectl logs forgejo-runner-0 -c docker -f`.

**Tier 2 — `test-docker` on `docker`.**
Pass: run `success`; `docker version` output in the log shows Server
`29.2.1` (the DinD daemon, reached via `DOCKER_HOST`).
Fail mode "Cannot connect to the Docker daemon at tcp://docker.internal:2375"
→ apply **Fallback A**: in the ConfigMap `container:` block, replace
`options: "--add-host=docker.internal:host-gateway"` with:

```yaml
      options: "--volume /var/run/docker.sock:/var/run/docker.sock"
      valid_volumes:
        - /var/run/docker.sock
```

and delete the `DOCKER_HOST:` line from `runner.envs`. Push, restart pod
(`kubectl delete pod forgejo-runner-0`), re-run Tier 2. (The socket exists
in the dind container at `/var/run/docker.sock` — verified.)

**Tier 3 — `test-build-push` (needs user setup first).**
User one-time setup:
1. Forgejo → Settings → Applications → generate a token with the
   `write:package` scope.
2. Repo `michael/homelab` → Settings → Actions → Secrets: add
   `FORGEJO_USERNAME` = `michael`, `FORGEJO_TOKEN` = that token.

Pass: run `success`; the image `homelab-ci-smoke` appears under michael's
Packages in the UI (packages are already enabled instance-wide — verified).
Then delete the throwaway package.

**Tier 4 — `validate-manifests` still green.**
The commit-B push itself runs it; also confirm the next day's 12:01 run is
green. Pass: `status: success` on the API check above.

## Cleanup

- If Fallback B was used: delete the dead offline runner entry (old id 272)
  in Site Administration → Actions → Runners.
- Keep the `runner.envs.GITHUB_SERVER_URL` entry as is — `checkout@v4` uses
  it to clone via the internal Service URL, which keeps clone traffic
  off the external network path.

## Rollback

```bash
git revert <commit-B-sha> <commit-A-sha>
git push
```

Flux re-applies the old pod spec; the pod rolls back and the daemon
re-declares the old labels (config labels revert with the ConfigMap). The
registration on the PVC is never touched by this plan, so no runner entry
changes identity. One transient validate run may be red in either direction
(image/Workflow flip race) — it self-heals on the next run. If Fallback B
was used, also delete the extra runner entry from the UI.

## Open questions for the user

1. Confirm you're happy dropping the `kaniko` label (nothing references it;
   test workflow was already deleted).
2. Tier 3 needs the one-time token/secret setup — do it before running
   `test-build-push`, or skip Tier 3 for now.
3. Two StorageClasses are marked default on this cluster (`local-path` and
   `longhorn`). Unrelated to this plan, but worth fixing separately.
