# Runbook: Off-site backup setup and restore

Sets up the S3 copy of `/var/lib/longhorn-backups`. The manifest stays out of `manifests/kustomization.yaml` until step 5, so nothing fires before its Secret exists.

**Expected cost:** about $1 a month for roughly 35 GB in S3 Standard, plus up to 30 days of pruned data. This is an estimate, and the budget alert covers it being wrong.

## 1. Prepare the AWS account

1. Create an AWS account and turn on MFA for the root user.
2. Create an admin IAM user or IAM Identity Center login for daily use. Don't use root keys.
3. Install the tools and sign in:

```bash
mise use -g aws-cli restic terraform
```

```bash
aws configure sso
```

```bash
aws sts get-caller-identity
```

## 2. Create the state bucket

```bash
terraform -chdir=terraform/bootstrap init
```

```bash
terraform -chdir=terraform/bootstrap apply
```

Note the `state_bucket` output. This stack's local state stays on your machine and is ignored by Git.

## 3. Create the backup infrastructure

```bash
terraform -chdir=terraform/offsite-backups init -backend-config="bucket=<state_bucket>"
```

```bash
terraform -chdir=terraform/offsite-backups apply -var="budget_alert_email=<your email>"
```

Then create the restic access key by hand, so the secret stays out of Terraform state:

```bash
aws iam create-access-key --user-name homelab-restic
```

## 4. Store the secrets

Generate a restic password, and **save it in a password manager that does not depend on this cluster**. Vaultwarden runs here, so it doesn't count on its own. Without this password, the off-site backups can't be read.

```bash
openssl rand -base64 36
```

Add the Secret with `sops edit`. Never re-encrypt the file from a plaintext copy.

```bash
sops edit manifests/secrets/secrets.sops.yaml
```

```yaml
---
apiVersion: v1
kind: Secret
metadata:
  name: offsite-backup-secrets
  namespace: default
type: Opaque
stringData:
  AWS_ACCESS_KEY_ID: <from step 3>
  AWS_SECRET_ACCESS_KEY: <from step 3>
  RESTIC_PASSWORD: <generated above>
  RESTIC_REPOSITORY: <restic_repository output>
```

Check the decrypted diff shows only this addition before committing.

Also keep the age private key outside the cluster. It decrypts every Secret in this repo, so a rebuild can't start without it.

## 5. Turn it on

Add `infrastructure/offsite-backup.yaml` to `manifests/kustomization.yaml`, merge, and wait for Flux. Then run the first backup instead of waiting for 05:00:

```bash
kubectl create job --from=cronjob/offsite-backup offsite-backup-initial
```

```bash
kubectl logs -f job/offsite-backup-initial
```

The first run uploads everything, so expect it to take a while. Later runs send only what changed.

## 6. Prove it works

```bash
kubectl create job --from=cronjob/offsite-backup-check offsite-backup-check-initial
```

```bash
kubectl logs -f job/offsite-backup-check-initial
```

Then test the key's limits. A delete should succeed, leaving a delete marker. Removing a specific version should fail with `AccessDenied`.

## Restore

From any machine, with the four Secret values exported as environment variables:

```bash
restic snapshots
```

```bash
restic restore latest --target ./restored --include /backups/postgres-dumps
```

If backups were deleted from the bucket, list the versions and remove the delete markers with your admin login, within 30 days:

```bash
aws s3api list-object-versions --bucket <bucket> --prefix restic/
```

## Next: the restore drill

Once the first snapshot exists, the drill can begin: bring up a temporary EKS cluster with Terraform, bootstrap Flux, restore the data, time it, verify it, and destroy the cluster. The result becomes a post-mortem-style report in `docs/postmortems/`.
