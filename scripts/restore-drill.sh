#!/usr/bin/env bash
# Steps of the EKS restore drill. See docs/runbooks/eks-restore-drill.md.
#
#   baseline       record live repo refs and row counts (reads production)
#   secrets        send the drill's Secrets to the drill cluster
#   volumes        restore the Forgejo volumes from the backupstore
#   kaneo          load the Kaneo dump, then start Kaneo
#   verify         compare the restored apps with the baseline
#   teardown-check list anything still billable after terraform destroy
#
# Every step but baseline runs against the restore-drill kubeconfig context
# only, so none of them can touch production. Each line of output is
# timestamped, which gives the write-up its timeline.
set -euo pipefail

DRILL=restore-drill
PROD=${PROD_CONTEXT:-default}
OUT=${DRILL_OUTPUT:-./drill-output}
REGION=us-west-2
NFS_URL=nfs://172.20.200.50:/opt/backupstore
WAIT_TIMEOUT=${WAIT_TIMEOUT:-1800}

log() { printf '%s %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }
k() { kubectl --context "$DRILL" "$@"; }

# Polls until a command succeeds, and stops the step if it never does. A silent
# wait looks the same as a slow one, so none of them may run forever.
wait_for() {
  local what=$1 deadline=$((SECONDS + WAIT_TIMEOUT))
  shift
  until "$@"; do
    ((SECONDS < deadline)) || {
      echo "Timed out after ${WAIT_TIMEOUT}s waiting for $what" >&2
      exit 1
    }
    sleep 10
  done
}

require_drill() {
  [[ "$(kubectl config get-contexts -o name)" == *"$DRILL"* ]] || {
    echo "No $DRILL context. Run the kubeconfig_command Terraform output first." >&2
    exit 1
  }
}

# Prints one line per repository: its path and a hash of all its refs.
repo_refs() {
  kubectl --context "$1" exec deploy/forgejo -c forgejo -- sh -c '
    cd /data/git/repositories
    find . -type d -name "*.git" -prune | sort | while read -r repo; do
      refs=$(git -c safe.directory="*" --git-dir="$repo" for-each-ref \
        --format="%(objectname) %(refname)" | sha256sum | cut -d" " -f1)
      echo "$repo $refs"
    done'
}

# Prints an exact row count for every table in the public schema.
row_counts() {
  local context=$1 target=$2 container=$3 db=$4
  kubectl --context "$context" exec "$target" -c "$container" -- psql -U "$db" -d "$db" -tA -c "
    SELECT table_name, (xpath('/row/c/text()',
      query_to_xml(format('SELECT count(*) AS c FROM %I', table_name), false, true, '')))[1]::text
    FROM information_schema.tables
    WHERE table_schema = 'public' AND table_type = 'BASE TABLE'
    ORDER BY 1"
}

baseline() {
  mkdir -p "$OUT"
  repo_refs "$PROD" >"$OUT/refs.baseline"
  row_counts "$PROD" deploy/forgejo postgres forgejo >"$OUT/forgejo-rows.baseline"
  row_counts "$PROD" deploy/kaneo-postgres postgres kaneo >"$OUT/kaneo-rows.baseline"
  log "baseline: $(wc -l <"$OUT/refs.baseline") repos recorded in $OUT"
}

# Run this in a terminal outside the app. It decrypts locally, and the values
# go straight to the cluster without being printed. The AWS keys are removed
# from drill-restic so restic uses the read-only role, not the production key.
secrets() {
  require_drill
  local plain
  plain=$(sops -d manifests/secrets/secrets.sops.yaml)

  for name in forgejo-secrets kaneo-secrets kaneo-db-secrets; do
    NAME=$name yq 'select(.metadata.name == env(NAME))' <<<"$plain" | k apply -f - >/dev/null
    log "secrets: applied $name"
  done

  yq 'select(.metadata.name == "offsite-backup-secrets")
    | .metadata.name = "drill-restic"
    | del(.data.AWS_ACCESS_KEY_ID, .data.AWS_SECRET_ACCESS_KEY,
          .stringData.AWS_ACCESS_KEY_ID, .stringData.AWS_SECRET_ACCESS_KEY)' <<<"$plain" |
    k apply -f - >/dev/null
  log "secrets: applied drill-restic"
}

# Creates a Longhorn volume from a PVC's newest backup, plus the PV that the
# patched PVC in clusters/drill/apps/core binds to.
restore_volume() {
  local pvc=$1 name=$2 backup_volume source backup size

  backup_volume=$(k -n longhorn-system get backupvolumes.longhorn.io -o json | jq -r --arg pvc "$pvc" '
    [.items[] | select((.status.labels.KubernetesStatus // "{}" | fromjson).pvcName == $pvc)]
    | sort_by(.status.lastBackupAt) | last | .metadata.name')
  [[ -n "$backup_volume" && "$backup_volume" != null ]] || {
    echo "No backup found for $pvc" >&2
    exit 1
  }

  source=$(k -n longhorn-system get backupvolumes.longhorn.io "$backup_volume" -o jsonpath='{.spec.volumeName}')
  backup=$(k -n longhorn-system get backupvolumes.longhorn.io "$backup_volume" -o jsonpath='{.status.lastBackupName}')
  size=$(k -n longhorn-system get backupvolumes.longhorn.io "$backup_volume" -o jsonpath='{.status.size}')
  log "volumes: restoring $pvc from $backup"

  k apply -f - <<EOF
apiVersion: longhorn.io/v1beta2
kind: Volume
metadata:
  name: $name
  namespace: longhorn-system
spec:
  accessMode: rwo
  backupTargetName: default
  dataEngine: v1
  frontend: blockdev
  fromBackup: "$NFS_URL?backup=$backup&volume=$source"
  numberOfReplicas: 1
  size: "$size"
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: $name
spec:
  accessModes: ["ReadWriteOnce"]
  capacity:
    storage: "$size"
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  csi:
    driver: driver.longhorn.io
    fsType: ext4
    volumeHandle: $name
EOF
}

backup_volumes_listed() {
  k -n longhorn-system get backupvolumes.longhorn.io -o name | grep -q .
}

# Don't wait for "detached": the waiting Forgejo pod attaches the volume as soon
# as the restore ends, so that state can pass between two polls. It did in the
# first drill, and the step hung for 2.5 hours with Forgejo already running.
volume_restored() {
  [[ "$(k -n longhorn-system get volumes.longhorn.io "$1" -o json |
    jq -r '.status.restoreRequired == false')" == true ]]
}

wait_restored() {
  wait_for "$1 to restore" volume_restored "$1"
  log "volumes: $1 restored"
}

volumes() {
  require_drill
  # Set SKIP_RESTIC_WAIT=1 to resume after the Job has already done its work.
  [[ -n "${SKIP_RESTIC_WAIT:-}" ]] || k wait --for=condition=complete --timeout=90m job/drill-restic-restore
  log "volumes: backupstore rebuilt from S3"

  wait_for "Longhorn to list the backups" backup_volumes_listed

  restore_volume forgejo-data-pvc drill-forgejo-data
  restore_volume forgejo-db-pvc-17 drill-forgejo-db
  wait_restored drill-forgejo-data
  wait_restored drill-forgejo-db

  k wait --for=condition=available --timeout=15m deploy/forgejo
  log "volumes: Forgejo is available"
}

kaneo() {
  require_drill
  local store dump
  k wait --for=condition=available --timeout=10m deploy/kaneo-postgres
  store=$(k get pod -l app=drill-backupstore -o name | head -1)
  dump=$(k exec "$store" -- sh -c 'ls -1t /opt/backupstore/postgres-dumps/postgres-kaneo-*.sql.gz | head -1')
  log "kaneo: loading $dump"

  # pg_dumpall recreates the role and database, which already exist here, so
  # those two errors are expected. verify is what decides if this worked.
  mkdir -p "$OUT"
  k exec "$store" -- cat "$dump" | gunzip |
    k exec -i deploy/kaneo-postgres -- psql -U kaneo -d postgres >/dev/null 2>"$OUT/kaneo-load.log" || true
  log "kaneo: load finished with $(grep -c ERROR "$OUT/kaneo-load.log" || true) errors, see $OUT/kaneo-load.log"

  flux --context "$DRILL" resume kustomization drill-kaneo
  k wait --for=condition=available --timeout=10m deploy/kaneo
  log "kaneo: available"
}

verify() {
  require_drill
  local failed

  repo_refs "$DRILL" >"$OUT/refs.restored"
  log "verify: $(wc -l <"$OUT/refs.baseline") repos at baseline, $(wc -l <"$OUT/refs.restored") restored"
  log "verify: refs that differ (only repos pushed to since the snapshot should appear):"
  diff "$OUT/refs.baseline" "$OUT/refs.restored" || true

  failed=$(k exec deploy/forgejo -c forgejo -- sh -c '
    cd /data/git/repositories
    find . -type d -name "*.git" -prune | while read -r repo; do
      git -c safe.directory="*" --git-dir="$repo" fsck --full >/dev/null 2>&1 || echo "$repo"
    done')
  log "verify: git fsck failures: ${failed:-none}"

  row_counts "$DRILL" deploy/forgejo postgres forgejo >"$OUT/forgejo-rows.restored"
  row_counts "$DRILL" deploy/kaneo-postgres postgres kaneo >"$OUT/kaneo-rows.restored"
  log "verify: Forgejo row differences:"
  diff "$OUT/forgejo-rows.baseline" "$OUT/forgejo-rows.restored" || true
  log "verify: Kaneo row differences:"
  diff "$OUT/kaneo-rows.baseline" "$OUT/kaneo-rows.restored" || true

  log "verify: mirrors must be off: $(k exec deploy/forgejo -c forgejo -- printenv FORGEJO__mirror__ENABLED)"
}

teardown_check() {
  local tag=Name=tag:Purpose,Values=restore-drill
  echo "EKS clusters:  $(aws eks list-clusters --region "$REGION" --query clusters --output text)"
  echo "Instances:     $(aws ec2 describe-instances --region "$REGION" --filters "$tag" \
    Name=instance-state-name,Values=pending,running,stopping,stopped \
    --query 'Reservations[].Instances[].InstanceId' --output text)"
  echo "Volumes:       $(aws ec2 describe-volumes --region "$REGION" --filters "$tag" \
    --query 'Volumes[].VolumeId' --output text)"
  echo "VPCs:          $(aws ec2 describe-vpcs --region "$REGION" --filters "$tag" \
    --query 'Vpcs[].VpcId' --output text)"
  echo "Load balancers: $(aws elbv2 describe-load-balancers --region "$REGION" \
    --query 'LoadBalancers[].LoadBalancerName' --output text)" \
    "$(aws elb describe-load-balancers --region "$REGION" \
      --query 'LoadBalancerDescriptions[].LoadBalancerName' --output text)"
  echo "Every line above must be empty."
}

case "${1:-}" in
  baseline) baseline ;;
  secrets) secrets ;;
  volumes) volumes ;;
  kaneo) kaneo ;;
  verify) verify ;;
  teardown-check) teardown_check ;;
  *)
    sed -n '2,10p' "$0"
    exit 1
    ;;
esac
