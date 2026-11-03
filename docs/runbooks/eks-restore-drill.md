# Runbook: EKS restore drill

**Status:** run once, on 2026-10-31. It passed, and Forgejo was ready in 1 hour 19 minutes. See the [post-mortem](../postmortems/2026-10-eks-restore-drill.md). Its script fixes haven't been run on a cluster yet.

Restores Forgejo from the S3 backup into a temporary EKS cluster, times it, proves the data is correct, and destroys the cluster. It closes the "Volume restore is unproven" limitation in the README.

## Scope

| App | Restore path | What it proves |
|---|---|---|
| Forgejo | restic to Longhorn backupstore to Longhorn volumes | Volume restore, and Postgres recovering from a crash-consistent copy of its data files |

The first drill also restored Kaneo from its `pg_dump` file, which proved the logical dump path. Kaneo was removed on 2026-11-03, so that path is no longer drilled. n8n's standalone Postgres dump is the candidate to replace it.

This is not a full stack restore. Bootstrapping all of `manifests/` is unsafe, because a second copy of the stack acts on the outside world:

| Component | What a second copy would do |
|---|---|
| Forgejo push mirrors | Force-push stale state over GitHub |
| cloudflared | Join the live tunnel and take production traffic |
| n8n | Run client workflows |
| Renovate, image automation | Open PRs and commit to the live repo |
| Forgejo runner | Pick up CI jobs |

So the drill has its own Flux path, `clusters/drill/`, listing only what it needs. It reuses the production manifests with patches. Forgejo runs with mirrors, cron, mail and Actions off, no runner, and `github.com` pointed at localhost in case a setting doesn't take effect. Access is `kubectl port-forward` only.

Flux is installed with `flux install`, not `flux bootstrap`, because bootstrap commits to the repo and adds a deploy key. The drill reads the public GitHub mirror with no credentials, so `clusters/drill/` must be on `main` first. Production ignores that path.

## Secrets

- The age key never goes on the cluster. It decrypts every Secret in this repo, and the drill needs only `forgejo-secrets`. It is decrypted locally and piped to `kubectl apply`, and Flux gets no decryption provider.
- Restore reads S3 through a drill-only IAM role with `s3:GetObject` and `s3:ListBucket`, attached by EKS Pod Identity. It can't write, so restic runs with `--no-lock`. The production key stays in production.
- `RESTIC_PASSWORD` goes in as a temporary Secret and is destroyed with the cluster.

Don't print any of these into a chat. Run them in a terminal outside the app.

## Infrastructure

`terraform/restore-drill/`, separate state from `offsite-backups`, so destroying it can't touch the bucket.

- EKS on Kubernetes 1.34, one minor above the cluster's 1.33 and on standard support until 2026-12-01. After that date, use the oldest version still on standard support.
- Two `t3.large` on-demand nodes with 100 GB gp3, in public subnets. The account's on-demand limit is 5 vCPUs, so these four leave no room for a third node.
- No NAT gateway. An S3 gateway endpoint keeps restore traffic in the region, which is free.
- API endpoint limited to the home IP.

## Expected cost

| Item | Per hour |
|---|---|
| EKS control plane, standard support | $0.10 |
| Two `t3.large` | about $0.17 |
| EBS and public IPv4 | about $0.03 |
| **Total** | **about $0.30** |

About $1 for a three-hour run, and under $3 with a retry. The first drill ran for about four hours, for about $1.20. The `t3.large` rate of $0.0832 was checked against the AWS Price List on 2026-10-31, and the EBS and IPv4 figure is an estimate. A version in extended support costs $0.60 an hour for the control plane, so check the version first.

A forgotten cluster costs about $7 a day, so the run isn't over until the check in step 8 passes.

## Procedure

Run against an automated nightly snapshot, not one taken by hand. `scripts/restore-drill.sh` runs every drill step against the `restore-drill` kubeconfig context only, and timestamps its output for the write-up. It needs `yq` (`mise use -g yq`).

1. **Preflight.** Confirm the nightly snapshot exists and `restic check` is clean, then record live repo refs and row counts:

   ```bash
   scripts/restore-drill.sh baseline
   ```

2. **Start the clock** and create the cluster. `<state_bucket>` is the bootstrap output:

   ```bash
   terraform -chdir=terraform/restore-drill init -backend-config="bucket=<state_bucket>"
   ```

   ```bash
   terraform -chdir=terraform/restore-drill apply -var="home_ip_cidr=$(curl -s https://checkip.amazonaws.com)/32"
   ```

   Then run the `kubeconfig_command` output.

3. **Install Flux** on the drill cluster. This installs Longhorn v1.10.1 and starts the restic Job:

   ```bash
   flux --context restore-drill install --components=source-controller,kustomize-controller,helm-controller
   ```

   ```bash
   kubectl --context restore-drill apply -f clusters/drill/sync.yaml
   ```

4. **Send the secrets** from a terminal outside the app:

   ```bash
   scripts/restore-drill.sh secrets
   ```

5. **Restore.** Waits for restic to rebuild the backupstore, then restores `forgejo-data-pvc` and `forgejo-db-pvc-17` and waits for Forgejo. Restic took 43 minutes in the first drill, and the volumes took a few more. The step prints nothing while it waits, so check `kubectl get pods` and the volume states if it goes quiet for long after that. Each volume wait stops the step after 30 minutes, and `WAIT_TIMEOUT` (in seconds) changes that:

   ```bash
   scripts/restore-drill.sh volumes
   ```

   If the Job has already restored the data, resume with `SKIP_RESTIC_WAIT=1 scripts/restore-drill.sh volumes`. Stop the clock when Forgejo is available.

6. **Verify** against step 1. Refs and row counts can differ only for changes made after the snapshot, and the data's age is the recovery point. Also clone a public repo that has refs through `kubectl port-forward`, because 35 repos are empty:

   ```bash
   scripts/restore-drill.sh verify
   ```

7. **Destroy and confirm.** Keep `drill-output/` for the write-up. The check must print nothing billable:

   ```bash
   terraform -chdir=terraform/restore-drill destroy -var="home_ip_cidr=$(curl -s https://checkip.amazonaws.com)/32"
   ```

   ```bash
   scripts/restore-drill.sh teardown-check
   ```

   Then remove the `restore-drill` context, cluster and user from your kubeconfig.

8. **Write it up** in `docs/postmortems/`, including everything that went wrong. Update the README, and add the measured time to the resumes.

## What the first drill settled

- **Longhorn on Amazon Linux 2023.** It runs, with the launch template installing the iSCSI and NFS client tools at boot.
- **The in-cluster NFS server.** The patched test image works.
- **Kaneo's dump.** `pg_dumpall` from a Postgres 17 client loads into a Postgres 16 server. Expect 6 harmless errors: the existing role and database, and four for `transaction_timeout`.
- **Longhorn v1.10.1 on Kubernetes 1.34.** It worked for this drill, though no source lists 1.34 as tested.
- **Fallback if Longhorn won't install.** Longhorn's documented offline recovery writes a backup to a raw image without a running Longhorn system. It wasn't needed, and it proves less.

## Pass criteria

- Forgejo runs on EKS from S3 data alone.
- Every Forgejo repo passes `git fsck`, and `HEAD` matches the snapshot's data.
- Measured recovery time and recovery point are recorded.
- Nothing billable remains, and GitHub, the tunnel and production see no change.
