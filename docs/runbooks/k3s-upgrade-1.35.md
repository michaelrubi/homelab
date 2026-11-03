# Runbook: k3s 1.33 → 1.35, then Flux 2.10

Flux v2.10.0 ([#165](https://git.rubiconetic.com/michael/homelab/pulls/165)) needs Kubernetes 1.35.2 or later, and the cluster runs v1.33.6+k3s1. Flux 2.9 already wants 1.34 or later, so the first step below also brings the running Flux back into its support range.

This plan has not been run yet. Versions and findings are from 2026-11-02, so re-check them before starting.

| Phase | Change | Soak before the next phase |
|---|---|---|
| 1 | k3s → v1.34.12+k3s1 | One Sunday kured reboot |
| 2 | k3s → v1.35.9+k3s1 | One Sunday kured reboot |
| 3 | Flux → v2.10.0 (#165) | A few days |
| 4 | Image controllers → v1.3.0 | None |

- **Downtime:** the Kubernetes API is down for about a minute per node restart. Running pods keep running, though Traefik restarts on its new chart in both k3s phases.
- **Needs:** `kubectl`, SSH with sudo to both nodes, and `age` on the workstation.
- **Don't merge to `main`** during a k3s phase, apart from the CI change in its last step.

## Decisions

- **Stop at 1.35.** It's the smallest move that satisfies Flux, and it stays inside Flux 2.9's range if phase 3 has to wait.
- **One minor at a time.** Kubernetes doesn't support skipping a minor.
- **Go straight to the latest 1.34 patch.** An extra stop at v1.33.13 adds a restart and gains nothing, because it carries the same Traefik chart jump.
- **Replace the binary, don't rerun the install script.** The script rewrites the systemd unit, and these nodes depend on `--node-ip`, `--advertise-address` and `--flannel-iface tailscale0`. Losing those would break networking over Tailscale.
- **Don't drain.** Restarting k3s leaves containers running. A drain would push every pod onto one 8 GiB node, and total requests already exceed one node's capacity. Longhorn's `block-if-contains-last-replica` policy could also stall it.
- **Leave Longhorn out of this.** It stays on v1.10.1 unless the check in step 0 fails. Longhorn v1.11.3 requires Kubernetes 1.34, so it can only follow phase 1, as its own change.

## Known impact

| Area | Finding | Action |
|---|---|---|
| API removals | The Kubernetes deprecation guide lists none after 1.32. Repo manifests use stable APIs | None |
| `Endpoints` v1 | Deprecated and still requested, but not removed | None |
| Traefik | k3s 1.34.12 moves the chart from 37 to 40. Its breaking change affects the ingress-nginx provider, which isn't used here. The cluster has no Ingress, Gateway or IngressRoute objects, and public traffic goes through cloudflared | Confirm the pod comes back |
| containerd | 2.1 → 2.2 | Check in the verify step |
| cgroups | 1.35 removes cgroup v1 by default. Ubuntu 24.04 uses v2 | Confirm in step 0 |
| Kubelet flag | `--pod-infra-container-image` is gone in 1.35. Neither node's `k3s.io/node-args` sets it | Confirm in step 0 |
| Metrics | 1.34 relabels some apiserver metrics. No alert in `manifests/` uses them. Bundled dashboards in kube-prometheus-stack 66 may show gaps | Cosmetic |
| Longhorn | **Unverified:** I couldn't confirm v1.10.1 is tested on 1.35 | Gate in step 0 |
| Prometheus Operator | **Unverified:** v0.79.0 on 1.35, chart 66 is well behind current | Watch in the verify step |

## 0. Before each k3s phase

**Pick the window.** Use a weekday evening. It must avoid the Sunday 03:00–05:00 kured window and the nightly backups (03:00 Longhorn, 04:00 Postgres dumps, 05:00 off-site, all Phoenix time).

**First time only, on both nodes:**

```bash
systemctl cat k3s k3s-agent 2>/dev/null | grep -E 'ExecStart=|^ +.*(server|agent|--)'
readlink -f "$(command -v k3s)"     # the runbook assumes /usr/local/bin/k3s
stat -fc %T /sys/fs/cgroup          # must print cgroup2fs
grep -rs pod-infra /etc/rancher/k3s # must print nothing
sudo ls /var/lib/rancher/k3s/server/db/ 2>/dev/null
```

The last command runs on thinkcentre01 and should show `state.db`. Neither node carries an etcd role, so the cluster should be on SQLite. If it shows `etcd/`, stop: the snapshot below doesn't apply.

**Longhorn gate, before phase 2:** check the [Longhorn compatibility matrix](https://www.suse.com/suse-longhorn/support-matrix/all-supported-versions/) for v1.10.x on Kubernetes 1.35. If it isn't listed, upgrade Longhorn first, as its own change.

**Confirm the cluster is healthy:**

```bash
kubectl get nodes
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
flux get kustomizations -A
kubectl -n longhorn-system get volumes.longhorn.io \
  -o custom-columns=NAME:.metadata.name,STATE:.status.state,ROBUSTNESS:.status.robustness
kubectl -n longhorn-system get recurringjobs.longhorn.io,backuptargets.longhorn.io
```

Every attached volume must be `healthy`. A detached volume reports `unknown`, which is normal (`forgejo-db-pvc` will show this until it's dropped). Confirm last night's Longhorn backups and `offsite-backup` run succeeded.

## 1. Snapshot the datastore

On the workstation, with the server stopped so SQLite is consistent. This takes the API down, not the workloads:

```bash
RECIPIENT=$(yq -r '.creation_rules[0].age' .sops.yaml)
ssh thinkcentre01 'sudo systemctl stop k3s'
ssh thinkcentre01 'sudo tar czf - /var/lib/rancher/k3s/server/db /var/lib/rancher/k3s/server/token' \
  | age -r "$RECIPIENT" > ~/k3s-server-$(date +%Y%m%d-%H%M).tar.gz.age
ssh thinkcentre01 'sudo cp -p /usr/local/bin/k3s /usr/local/bin/k3s.previous'
ssh thinkcentre02 'sudo cp -p /usr/local/bin/k3s /usr/local/bin/k3s.previous'
ls -lh ~/k3s-server-*.age
```

The snapshot holds every cluster Secret in the clear, so it's encrypted before it leaves the node. Don't start k3s again here. Step 2 does that on the new binary.

## 2. Upgrade the server

Set the version for the phase, then run on thinkcentre01. The server goes first, because a kubelet must not be newer than the API server.

```bash
K3S=v1.34.12+k3s1   # phase 2: v1.35.9+k3s1
V=${K3S/+/%2B}
cd "$(mktemp -d)"
curl -fsSLO "https://github.com/k3s-io/k3s/releases/download/$V/k3s"
curl -fsSLO "https://github.com/k3s-io/k3s/releases/download/$V/sha256sum-amd64.txt"
sha256sum -c --ignore-missing sha256sum-amd64.txt   # must print "k3s: OK"
sudo install -m 755 k3s /usr/local/bin/k3s
sudo systemctl start k3s
```

Wait for it from the workstation:

```bash
kubectl wait --for=condition=Ready node/thinkcentre01 --timeout=5m
kubectl get nodes
```

## 3. Upgrade the agent

Run the same download and checksum on thinkcentre02, then:

```bash
sudo install -m 755 k3s /usr/local/bin/k3s
sudo systemctl restart k3s-agent
```

## 4. Verify

```bash
kubectl get nodes -o wide   # both on the new version, containerd 2.2
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
kubectl -n kube-system get pods
flux reconcile kustomization flux-system --with-source
flux get kustomizations -A
kubectl -n longhorn-system get volumes.longhorn.io \
  -o custom-columns=NAME:.metadata.name,STATE:.status.state,ROBUSTNESS:.status.robustness
kubectl -n monitoring get pods
```

Then check by hand:

- Forgejo, Kaneo and n8n load through their public hostnames, which proves cloudflared and cluster networking.
- Pods on different nodes can reach each other. Flannel runs over Tailscale here, and it has been the fragile part of this cluster.
- Alertmanager shows no new alerts, and the next nightly backups succeed.

## 5. Record the version

After the phase passes, open a PR that updates `K8S_VERSION` and its comment in `.forgejo/workflows/validate-manifests.yml`, and the version in `README.md` (badge and Platform row). Before phase 3, also update the EKS version note in `docs/runbooks/eks-restore-drill.md`: that drill runs on 1.34, which leaves standard support on 2026-12-01.

Let one Sunday kured reboot pass before the next phase. It restarts both nodes on the new version, which is the test a live restart doesn't give.

## Rollback for a k3s phase

**Agent only:** on thinkcentre02, restore `/usr/local/bin/k3s.previous` and restart `k3s-agent`.

**Server:** Kubernetes doesn't support a downgrade on the same datastore, so restore the snapshot too. Cluster state written since then is lost, and Flux re-applies what's in git.

```bash
# On thinkcentre02
sudo systemctl stop k3s-agent
sudo cp -p /usr/local/bin/k3s.previous /usr/local/bin/k3s

# On thinkcentre01
sudo systemctl stop k3s
sudo cp -p /usr/local/bin/k3s.previous /usr/local/bin/k3s
sudo mv /var/lib/rancher/k3s/server/db /var/lib/rancher/k3s/server/db.failed

# On the workstation, with the age private key for the recipient used in step 1
age -d -i <key-file> ~/k3s-server-<stamp>.tar.gz.age \
  | ssh thinkcentre01 'sudo tar xzf - -C /'

# Then start thinkcentre01's k3s, followed by thinkcentre02's k3s-agent
```

Traefik's bundled chart follows the k3s version, so it rolls back with the binary. If a problem shows up after a soak, prefer fixing forward, because restoring an old snapshot would roll back cluster state from before the soak.

## 6. Phase 3: Flux 2.10

Run this only with both nodes on 1.35 and a clean soak.

1. Update the local CLI, which is on 2.8.8, to 2.10.0 in mise. Then run `flux check --pre`.
2. Rebase #165 by ticking its Renovate checkbox, and wait for CI.
3. Confirm the release notes' breaking changes still don't apply. As of 2026-11-02:
   - Nothing uses `serviceaccounts/token`, `kubeConfig` or the `ObjectLevelWorkloadIdentity` gate.
   - `Provider/alertmanager` and `Alert/flux-reconciliation-errors` use none of the fields dropped in `v1`.
4. Merge #165, then run `flux check` and `flux get all -A`.
5. Prove alerting still works, using the alert-router harness in `scripts/`. A broken notification path is the failure this cluster has been caught by before ([post-mortem](../postmortems/2026-09-silent-alerts.md)).
6. In a later PR, move `manifests/infrastructure/flux-alerts.yaml` from `v1beta3` to `v1`.

**Rollback is not a clean revert.** Once the notification CRDs store `v1`, an older CRD without that version can be rejected until `status.storedVersions` is fixed by hand. If Flux itself breaks, it can't deploy its own repair, so you'd apply the previous `gotk-components.yaml` with `kubectl`.

## 7. Phase 4: image controllers

Move them in step with Flux, as a separate PR. Renovate doesn't update `clusters/my-cluster/flux-system/gotk-components-image.yaml`, so it stays at the Flux v2.8.6 versions (reflector v1.1.1, automation v1.1.2) until someone changes it. Flux v2.10.0 ships v1.3.0 of both.

1. Regenerate the image controller resources with the v2.10.0 CLI, using `flux install --components-extra=image-reflector-controller,image-automation-controller --export`, and replace the file's contents. Update its header comment too.
2. Merge. In v2.10 the Flux artifact storage backend becomes the default, which wipes the `ImageRepository` tag database and rescans on first reconcile. Accept this rather than setting `FluxStorage=false`: the only consumer is `mrubi86/torrenter`, and a rescan just re-reads its tags.
3. Confirm with `flux get images all -A` that the latest tag is found, and that the next torrenter image still deploys.

## Afterwards

- Delete `/usr/local/bin/k3s.previous` on both nodes and the `~/k3s-server-*.age` snapshots.
- Consider adding the k3s version to Renovate's scope, so the cluster doesn't drift this far again.
- Upgrade Longhorn as its own change.
