# Postiz Integration Plan

## What it is

Postiz is a self-hosted social-media scheduling tool — Buffer/Hypefury alternative — that
schedules posts to ~20 platforms (X, LinkedIn, Instagram, Threads, Bluesky, Mastodon, Discord,
Reddit, YouTube, TikTok, Pinterest, Slack, Telegram, Dribbble, Farcaster, etc.). The repo is
https://github.com/gitroomhq/postiz-app, AGPL-3.0 licensed, with a published container image
at `ghcr.io/gitroomhq/postiz-app` and an official (very-early) Helm chart at
`gitroomhq/postiz-helmchart`.

## Architecture (from the official image + docker-compose + source)

The single published image `ghcr.io/gitroomhq/postiz-app` is a **monolith**:

- **nginx** listening on port 5000 inside the container. Routes `/api/*` → backend :3000,
  `/uploads/*` → static volume, `/` → frontend :4200.
- **pm2** running three Node processes in the same container:
  - `backend` (NestJS API, port 3000) — owns the HTTP API, Prisma DB, OAuth flows, scheduling
    decisions
  - `frontend` (NextJS, port 4200) — the React UI
  - `orchestrator` (NestJS, port 3002 healthcheck) — the **Temporal worker**. Runs scheduled
    workflow activities (publish posts, polls, AI jobs)
- Image layer scan (`extract_configs.py` in this folder) confirms the entrypoint is
  `sh -c 'nginx && pnpm run pm2'`, working dir `/app`, runs as user `www`.

It does NOT bundle Temporal itself. The docker-compose ships a **separate Temporal stack**:
`temporal-postgres` (postgres:16) + `temporal-elasticsearch` (7.17.27) +
`temporalio/auto-setup:1.28.1` + `temporal-admin-tools` + `temporal-ui`. This is non-trivial
(~5 extra containers) but **the orchestrator cannot run without it** — confirmed in
`temporal.module.ts`:

```
address: process.env.TEMPORAL_ADDRESS || 'localhost:7233',
namespace: process.env.TEMPORAL_NAMESPACE || 'default',
```

And the orchestrator's `onModuleInit` registers required search attributes
(`organizationId`, `postId`) on the Temporal namespace at startup.

## What we need to deploy

1. **Postiz monolith** (Deployment + Service + 2 PVCs)
2. **Postgres 17** for the app DB (Prisma)
3. **Redis 7** for queue/cache
4. **Temporal stack** (postgres + elasticsearch + temporal server + UI + admin tools)
   — 5 containers, ~256MB heap on Elasticsearch, ~700MB image size

That's 9–10 containers total, several of them stateful. On our 2-node / 8-CPU / 16GB cluster
this is fine but not free.

## Storage footprint

- `/uploads` PVC: media uploaded by users. Recommend 20Gi, RWX would be ideal but Longhorn
  RWO is fine for a single replica.
- `/config` PVC: app config + encryption keys (Prisma stores keys here). 1Gi.
- postiz-postgres PVC: 5Gi matches upstream. Prisma schemas grow slowly but scheduled-posts
  history will accumulate; 10Gi is more honest.
- postiz-redis PVC: 1Gi (it streams just a queue/cache, no persistence in upstream's intent).
- temporal-postgres: 5Gi (workflow history).
- temporal-elasticsearch: skip persistent volume — Temporal's ES is a query accelerator,
  history lives in postgres. `emptyDir` is safe.

## Networking model (matches existing homelab)

- `postiz-service` — **LoadBalancer** (Tailscale), exposes port 5000 (nginx). Reachable only
  via your tailnet, just like pgweb/vaultwarden/homepage. NOT public-internet.
- `postiz-public-ingress` (optional) — fronted by Cloudflared + public hostname for OAuth
  callbacks. X, LinkedIn, GitHub OAuth providers require a public redirect URL. The official
  `MAIN_URL`/`FRONTEND_URL` must match whatever you set this to.

  → **Recommendation: start Tailscale-only. Add Cloudflared later only if you want to use
    a channel that requires public OAuth redirects. Mastodon, Bluesky, Reddit, Discord,
    Telegram work with Tailscale-only because they use token-based auth, not OAuth callbacks.**

## Secrets surface (postiz-secrets secret)

From the Helm chart `values.yaml` + `.env.example`:

Required:
- `JWT_SECRET` — must be unique per install (used to sign session tokens)
- `DATABASE_URL` — `postgresql://user:pass@postiz-postgres:5432/postiz`
- `REDIS_URL` — `redis://:password@postiz-redis:6379`

Per-provider OAuth client id/secret (leave blank for unused providers; ~30 vars total).
We'll only put the keys in the secret for providers you actually want to enable. Resend
key for email-based activation is optional — without it users auto-activate.

Storage: leave `STORAGE_PROVIDER=local` for v1. Cloudflare R2 is the future upgrade path
if /uploads outgrows Longhorn.

## What goes where in the repo

```
manifests/
  social/                          # NEW category
    postiz-app.yaml                # Deployment + Service + PVCs (uploads + config)
    postiz-postgres.yaml           # postgres:17 + Service + PVC
    postiz-redis.yaml              # redis:7 + Service + PVC
    postiz-temporal.yaml           # 5-container Temporal stack in 1 file
manifests/kustomization.yaml       # add 4 entries
secrets.plain.yaml                 # add postiz-secrets, postiz-db-secrets, postiz-redis-secrets, temporal-db-secrets
docs/postiz-research/              # this folder (already created)
```

All four social/ files will follow the established patterns: `reloader.stakater.com/auto`
annotation on the Deployment, securityContext with `fsGroup: 1000`, Recreate strategy for
stateful pods, requests+limits, liveness/readiness probes on `:5000` (the nginx port).

## Decision points before I write code

1. **Public OAuth?** — Tailscale-only is simpler and supports ~70% of providers out of the
   box. Add Cloudflared public hostname later if needed.
2. **Where to live?** — new `social/` category (you've used `media/`, `productivity/`,
   `automation/`, `infrastructure/`) or piggyback on `media/`?
3. **Provider priority for v1** — empty is fine (you can add providers after first login).
   Default to leaving all 30 provider keys blank; you'll fill them in as needed.
4. **Temporal UI exposure?** — `temporal-ui-service` LoadBalancer for debugging? Or just
   forward port via kubectl when you need it? I'd default to kubectl port-forward to keep
   the attack surface down.

## Risks / things to know

- The app runs **3 Node processes in 1 container via pm2**. If one dies, pm2 restarts it
  but the whole pod stays up. Memory limit needs to account for all three (start at 1Gi
  limit, monitor and tune).
- **Prisma db push runs on every container start** as part of `pm2-run` (`prisma-db-push`).
  This is destructive (accept-data-loss flag is set in package.json). Means schema drift
  between upgrades silently auto-resolves. Documented upstream behavior, but worth knowing.
- **AGPL-3.0**: any modifications you distribute must be published. You're self-hosting for
  personal use, so this only matters if you later redistribute a fork. Keep this in mind if
  you ever share configs publicly.
- **OAuth URL** must EXACTLY match the URL you access the app on. If MAIN_URL is
  `https://postiz.rubiconetic.com` and you access via Tailscale IP, OAuth providers will
  reject the callback. Pick one access pattern and stick with it.
- The official Helm chart is **in very active development** (their words). It's at v1.0.5
  with `appVersion: "1.3.0"` — note the upstream container image is currently labeled
  `v2.21.10` (different versioning scheme). We are NOT using the Helm chart — we're
  transcribing its intent into native manifests.

## Source files cached for reference

- `README.md` — upstream README
- `docker-compose.yaml` — full upstream docker-compose for production
- `helm-values.yaml` — official Helm chart values (canonical env surface)
- `helm-deployment.yaml` — official Helm chart deployment template
- `helm-secret.yaml` — official Helm chart secret template
- `orch-main.ts` — orchestrator entrypoint (confirms Temporal requirement)
- `extract_configs.py` — script that pulled nginx.conf + Dockerfile.dev + package.jsons
  directly from the published image layers (forensic verification of the image's actual
  runtime behavior)

