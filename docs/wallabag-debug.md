# Wallabag Debug Report

**Date:** 2026-04-02
**Status:** PARTIALLY RESOLVED — requires manual verification

---

## Symptom

`k get pods` showed wallabag in `CrashLoopBackOff`.

```
wallabag-6559ccfccb-8np9g   0/1     CrashLoopBackOff   3 (7s ago)   98s
```

---

## Root Cause

```
SQLSTATE[08006] [7] connection to server at "postgres" (10.43.253.49), port 5432 failed:
FATAL: password authentication failed for user "wallabag"
```

The wallabag app was trying to connect to postgres with credentials for a `wallabag` user/DB that **did not exist**.

---

## Investigation Steps

### 1. Checked wallabag deployment
Wallabag connects to:
- PostgreSQL at `postgres:5432`
- Redis at `localhost:6379` (this is also misconfigured — should be a Kubernetes service, not localhost)

Database credentials come from `wallabag-secrets` secret.

### 2. Checked postgres pods
```
NAME                        READY   STATUS
postgres-75d5557c55-lfvwx   0/1     Init:0/1        (stuck — new pod with broken init container)
postgres-dfb448d4b-f87f5     1/1     Running          (old pod — no wallabag init ever ran)
wallabag-6559ccfccb-8np9g   0/1     CrashLoopBackOff
```

**Key finding:** Two postgres pods existed:
- Old pod (11h running) held the PVC but never had the wallabag init container execute
- New pod was stuck because the PVC was already attached to the old pod (Multi-Attach error)

### 3. Checked postgres logs
```
FATAL: password authentication failed for user "wallabag"
FATAL: Role "wallabag" does not exist.
```

Confirmed: wallabag role was never created in postgres.

### 4. Examined postgres deployment manifest (`manifests/automation/n8n-pg.yaml`)

The deployment has an **init container** that tries to create the wallabag user:

```bash
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
  SELECT 'CREATE USER wallabag' WHERE NOT EXISTS ...
  SELECT 'CREATE DATABASE wallabag' WHERE NOT EXISTS ...
  GRANT ALL PRIVILEGES ON DATABASE wallabag TO wallabag;
  ALTER USER wallabag WITH PASSWORD '$WALLABAG_DB_PASSWORD';
EOSQL
```

**Critical bug:** The init container connects via Unix socket (`/var/run/postgresql/.s.PGSQL.5432`) to `localhost`. But init containers run **before** the main postgres container starts — postgres isn't running when the init container executes. This is a fundamental design flaw in the init container approach for database initialization.

### 5. Verified postgres authentication

From `pg_hba.conf`:
```
local   all             all                                     trust
host    all             all             127.0.0.1/32            trust
host all all all scram-sha-256
```

Local connections are `trust` (no password). Remote connections require `scram-sha-256`.

---

## Fixes Applied

### Fix 1: Deleted old postgres pod
Deleted `postgres-dfb448d4b-f87f5` to release the PVC, allowing the new pod to start.

### Fix 2: Manually created wallabag user and database

Since the init container is broken, created the user/DB manually:

```bash
# Create user
k exec postgres-dfb448d4b-dqhzz -- psql -U n8n -d n8n \
  -c "SELECT 'CREATE USER wallabag' WHERE NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'wallabag')\gexec"

# Create database
k exec postgres-dfb448d4b-dqhzz -- psql -U n8n -d n8n \
  -c "CREATE DATABASE wallabag;"

# Set password and grant privileges
k exec postgres-dfb448d4b-dqhzz -- psql -U n8n -d n8n \
  -c "GRANT ALL PRIVILEGES ON DATABASE wallabag TO wallabag;"
k exec postgres-dfb448d4b-dqhzz -- psql -U n8n -d n8n \
  -c "ALTER USER wallabag WITH PASSWORD '<password from wallabag-secrets>';"
```

---

## Remaining Issues

### 1. Init container is fundamentally broken
The postgres init container uses Unix socket connection to localhost, which fails because postgres isn't running when init containers execute. **Fix:** The init container should use TCP connection to the kubernetes service DNS name (e.g., `postgres.default.svc.cluster.local`), or use a separate Kubernetes Job instead of an init container.

### 2. Redis misconfiguration
Wallabag env: `SYMFONY__ENV__REDIS_DSN=redis://localhost:6379`

`localhost` in a Kubernetes pod refers to the pod itself, not a redis service. Either:
- Redis needs to be running as a sidecar in the same pod, or
- The env var should point to a redis service like `redis://redis:6379`

### 3. Postgres deployment still has broken init container
The manifest at `manifests/automation/n8n-pg.yaml` needs to be fixed so that future postgres deployments work correctly. The init container approach with Unix sockets is broken.

### 4. Need to verify wallabag is working
After the fixes, run:
```bash
k rollout restart deployment wallabag
k get pods -l app=wallabag
```
Then browse to https://wallabag.robin-mine.ts.net

---

## Files Involved

| File | Issue |
|------|-------|
| `manifests/automation/n8n-pg.yaml` | Init container uses localhost socket (broken) |
| `manifests/productivity/wallabag.yaml` | Redis DSN uses localhost (misconfigured) |
| `manifests/secrets/secrets.sops.yaml` | Contains encrypted wallabag credentials |

---

## Recommended Permanent Fixes

### For postgres init container:
Replace the init container approach with a separate Kubernetes Job that runs after postgres is ready, using TCP connection:

```yaml
# Instead of initContainers, use a post-startup Job that:
# 1. Waits for postgres to be ready
# 2. Connects via TCP to postgres.default.svc.cluster.local:5432
# 3. Creates the wallabag user and database
```

### For wallabag Redis DSN:
Change `redis://localhost:6379` to `redis://redis:6379` (or whatever the redis service name is), or remove it entirely if Redis isn't deployed.
