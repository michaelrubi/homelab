> **ARCHIVED — superseded.** Last verified 2026-07-02. The runner
> registration problem this plan targeted was fixed in `e209707`
> ("mint a real runner registration token"), and the runner has since been
> registering and polling. Kept for history only; nothing here is actionable.

---

# PLAN: Verify & Harden Forgejo Runner

**Status: supersedes the previous version of this file (2026-04). The "Mount Busy" issue that plan targeted is resolved. The runner is up and registered, but has never been verified to execute a job — this plan is the path to proving it works.**

**Last verified live: 2026-07-02, cluster at main@sha1:257bf2d**

## Why this plan exists

Two months ago the runner was crashing in a Mount Busy loop. Several fixes landed (3b507cb, d875134, fe46adb, a540c12) and the pod has been `2/2 Running` since. The runner daemon shows "poller launched" with no errors, the registration file is valid, and the DinD daemon is up. But there's no evidence a job has ever actually run on it.

This plan:
1. Proves the runner works end-to-end (Tiers 1 → 3).
2. Documents hardening items to address before treating the runner as production-grade.

## User Review Required

- **No manifest changes in Tiers 1-2.** Tier 3 may need a small secret plumbing change if we want to wire registry creds through Flux; the test workflow itself lives in a throwaway repo, not in this GitOps repo.
- **Test repo**: needs to be created on your Forgejo instance by you. Suggested: `rubiconetic/runner-smoke`. I don't have your Forgejo admin creds in the GitOps repo.
- **External network**: Tiers 1-2 don't need it. Tier 3's `actions/checkout@v4` requires default-allow egress; K3s default is allow-all and I see no NetworkPolicies in the repo, so this should work, but not yet verified end-to-end.
- **Container registry**: Tier 3 needs a destination. Default plan: Forgejo's built-in container registry. If you want ghcr.io or both, say so.
- **Hardening section is post-success.** Probes, resource limits, DinD TLS — all separate change set, not blocking the verification.

## Current state (verified 2026-07-02)

| Check                                  | Result                                                       |
|----------------------------------------|--------------------------------------------------------------|
| Flux reconciliation                    | True / applied (main@sha1:257bf2d)                           |
| `forgejo-runner-0` pod                 | 2/2 Running on thinkcentre01                                 |
| Registration file `/data/runner`       | id=270, uuid=d920cd8a..., labels=[docker, ubuntu-latest, kaniko] |
| Runner daemon log                      | "poller launched", no errors in last 2h                      |
| DinD daemon                            | Up on tcp://2375, buildkit initialized                       |
| Runner → Forgejo svc                   | OK (HTTP 200, real repos/search response)                    |
| Runner → DinD socket                   | OK (`nc -z localhost 2375`)                                  |

## Tier 1 — Confirm the runner picks up a job

**Goal**: prove Forgejo can deliver a job to the runner and the runner can complete it. No builds, no pushes.

**Setup** (you):
1. Create repo `rubiconetic/runner-smoke` on Forgejo (top-right `+` → New Repository).
2. Add a README so the default branch exists.

**Workflow** (`runner-smoke/.forgejo/workflows/simple-test.yml`):
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
          uname -a
          cat /etc/os-release | head -3
```

**Run**:
1. In the Forgejo UI: `runner-smoke` → Actions → "simple-test" → Run workflow.
2. In WSL: `kubectl logs -f forgejo-runner-0 -c runner`.
3. Refresh the Actions tab; expect a green checkmark.

**Pass criteria**: green checkmark in the Actions tab; runner log shows job start and completion.

**If it fails**:
- No "got job" / "running" in runner log → Forgejo isn't routing jobs. Check the runner is "Active" in `https://git.rubiconetic.com/-/admin/actions/runners`.
- "got job" but no completion → check the Actions UI for the failed step's stderr; the runner log will have the container error too.

## Tier 2 — Confirm the runner can do real work

**Goal**: prove the `docker` label can pull a real image and run it. This exercises the DinD socket from a sibling job container (not the runner daemon container).

**Workflow** (`runner-smoke/.forgejo/workflows/test-docker.yml`):
```yaml
name: test-docker
on:
  workflow_dispatch:
jobs:
  test:
    runs-on: docker
    steps:
      - name: Pull a real image
        run: docker pull alpine:3.20
      - name: Run it
        run: docker run --rm alpine:3.20 sh -c 'echo "From inside docker run: $(uname -a)"'
      - name: docker version
        run: docker version
```

**Run**: same as Tier 1.

**Pass criteria**: all three steps green; `docker version` shows the DinD server (~29.x) under "Server".

## Tier 3 — Build and push an image

**Goal**: prove the runner can replace GH Actions for your real workflow — build a container image, push to a registry.

**Decision needed**: which registry? Default plan: Forgejo's built-in container registry. Enable it first: Forgejo admin → Packages → Container. The exact push path format is shown in your admin UI; it varies by Forgejo version.

**Workflow** (`runner-smoke/.forgejo/workflows/build-push.yml`):
```yaml
name: build-push
on:
  workflow_dispatch:
jobs:
  build:
    runs-on: docker
    steps:
      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3
      - name: Login to Forgejo registry
        uses: docker/login-action@v3
        with:
          registry: forgejo-service.default.svc.cluster.local:3000
          username: ${{ secrets.FORGEJO_USERNAME }}
          password: ${{ secrets.FORGEJO_TOKEN }}
      - name: Build and push
        uses: docker/build-push-action@v5
        with:
          context: .
          push: true
          tags: forgejo-service.default.svc.cluster.local:3000/${{ gitea.repository }}:latest
```

**Dockerfile** at the repo root:
```dockerfile
FROM alpine:3.20
RUN echo "Built by Forgejo runner at $(date)" > /built.txt
CMD cat /built.txt
```

**Secrets**: add `FORGEJO_USERNAME` and `FORGEJO_TOKEN` to the repo's secrets via Forgejo UI (Settings → Actions → Secrets).

**Pass criteria**: workflow green; image appears in the registry with a fresh push timestamp.

**Note on in-cluster URL**: `forgejo-service.default.svc.cluster.local:3000` works because the job container shares the runner pod's network namespace. To pull the image from outside the cluster (e.g. into a deployment), use `git.rubiconetic.com` — the in-cluster URL is not resolvable from your laptop.

## Hardening (post-success, separate change set)

Not blocking the verification. Address when you're ready to stop babysitting.

| Item                                       | Why it matters                                                                | Suggested fix                                                    |
|--------------------------------------------|-------------------------------------------------------------------------------|------------------------------------------------------------------|
| No liveness probe on runner container      | If the poller dies, K8s won't restart the pod                                 | `livenessProbe` on a TCP socket or `/healthz` endpoint           |
| No readiness probe on runner container     | New pods may receive jobs before the poller is up                             | `readinessProbe` matching the above                              |
| No resource requests/limits on runner container | OOM risk, no QoS guarantees                                              | `requests: 256Mi/200m`, `limits: 512Mi/1000m` (match the n8n pattern) |
| No resource requests/limits on DinD container | Same                                                                       | Same                                                             |
| `DOCKER_TLS_CERTDIR=""`                    | DinD API accessible unencrypted on the pod's network namespace. Fine for a single-tenant cluster; bad if you ever run untrusted workflows | Switch to TLS-secured DinD with a sidecar CA when needed         |
| `GITHUB_SERVER_URL` in runner config       | Cosmetic, misleading — this isn't GitHub                                      | Drop the `envs:` block from the `runner-config` ConfigMap        |
| `privileged: true` on DinD                 | Required for DinD, but a misbehaving job has root on the node                 | Out of scope unless you want rootless DinD                       |

## Verification commands (post-tier)

```bash
# Pod health
kubectl get pods -l app=forgejo-runner

# Daemon log: look for new "got job" / completion entries
kubectl logs forgejo-runner-0 -c runner --since=1h

# Errors (should be empty)
kubectl logs forgejo-runner-0 -c runner --tail=200 | grep -iE 'error|fatal'

# DinD health
kubectl logs forgejo-runner-0 -c docker --tail=50
```

## Rollback / abort

- **Tier 1-3**: nothing to roll back in the GitOps repo. All test workflows live in `runner-smoke`. To stop: delete the workflow files or the repo.
- **Hardening**: each change is a separate commit. `git revert` per commit.
- **Whole plan abort**: no manifest changes have been made, so there's nothing to undo in this repo.

## Open questions

1. **Test repo creation**: should you create `rubiconetic/runner-smoke`? I can't (no Forgejo admin creds here).
2. **Tier 3 registry**: Forgejo built-in (default), ghcr.io, or both? The first is what makes the runner self-sufficient.
3. **When to start**: do you want to run Tier 1 now, or review the plan first?
