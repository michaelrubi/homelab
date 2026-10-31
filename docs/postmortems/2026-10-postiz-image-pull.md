# Post-mortem: Postiz down for 15 hours on an image pull

**Date:** 2026-10-30, 02:14 to 17:34 UTC
**Duration:** About 15 hours 20 minutes
**Impact:** Postiz was unavailable, including scheduling and publishing. No data loss.

## Summary

A routine Postiz version bump replaced the running pod with one that couldn't pull its image. The pod carried a pull secret for a private sidecar, and Kubernetes applies a pod's pull secrets to every image in it. GHCR answered 403 for the public Postiz image because of that credential, and `Recreate` had already removed the old pod. Alerts fired within about 15 minutes, repeated every 4 hours, and reached ntfy.sh, but the phone wasn't subscribed to the topics, so nothing arrived. The failure was found by chance during other work.

## Timeline

All times are UTC. Phoenix is 7 hours behind.

| Time | Event |
| :--- | :--- |
| 02:13 | The Renovate PR for `postiz-app` v2.25.0 to v2.25.3 is merged. |
| 02:14 | Flux rolls it out. `Recreate` stops the old pod first. |
| 02:19 | The new pod enters `ImagePullBackOff` on `postiz-app:v2.25.3`. |
| 02:30 | alert-router classifies `KubePodNotReady` as `page_now` and sends it to ntfy. |
| 06:35, 10:40, 14:45 | The same alert repeats on the 4-hour interval. |
| 17:27 | The failure is noticed while checking an unrelated merge. |
| 17:30 | The pull secret is removed from the pod in PR 159. |
| 17:34 | The new pod starts on thinkcentre02. Postiz recovers. |
| 10-31 02:12 | After the phone subscribes to both ntfy topics, test alerts on both paths arrive. |

## Root causes

**One credential covered every image in the pod.** `imagePullSecrets` sits at pod level, so the secret for the private sidecar also applied to the public Postiz image. An anonymous pull of that image worked. The cluster's authenticated pull got a 403. The most likely reason is an expired or revoked token, but the token itself was never tested.

**The credential's failure was invisible until a pull needed it.** Both images were cached on the node, so running pods gave no sign of a problem. The version bump was the first new pull.

**`Recreate` turned a failed pull into an outage.** The strategy is correct here because Postiz uses ReadWriteOnce volumes. It also means the old pod is gone before the new image is known to work.

**The phone wasn't subscribed to the alert topics.** Every test of the alert path stopped at Alertmanager and ntfy.sh, so the missing subscription went unnoticed.

## What went well

- The cluster half of the alert path worked. `KubePodNotReady` fired, alert-router logged no delivery errors, and ntfy.sh still held the messages from 10:40 onward when checked.
- The sidecar image stayed cached on thinkcentre02, which allowed a fix without a new token.

## What went wrong

- September's fix proved alerts could leave the cluster, and nothing has tested the last step to the phone since. Fifteen hours passed with pages going out and none arriving.
- The pages were raw Alertmanager JSON of about 2,000 characters with no title or priority, so they would have been hard to read even if they had arrived.
- A comment in the manifest called the pod-level secret harmless, which discouraged anyone from questioning it.

## Actions

| Action | Status |
| :--- | :--- |
| Remove the pod-level pull secret and explain why in the manifest | Done |
| Prefer thinkcentre02, where the sidecar image is cached | Done |
| Make `postiz-ai-proxy` public, then remove the node preference and `ghcr-pull-secret` | Open |
| Subscribe the phone to both ntfy topics and confirm with test alerts | Done |
| Send warning pages with a title, summary, and high priority instead of raw JSON | Done |
| Make critical pages readable too; they still go straight from Alertmanager as raw JSON | Open |
| Replace the warning topic, which was printed into an assistant session | Open |
| Send a test page by hand after any change to ntfy or the phone | Open |

## Lessons

- A pull secret is a dependency of every image in the pod, public ones included.
- Cached images hide broken registry credentials until the next rollout.
- `Recreate` needs a working image more than any other strategy, because there is no old pod left to serve traffic.
- An alert isn't delivered until a person has received it. A 200 from the notification service proves only the first hop.

## Evidence

PR 146 and PR 159. Prometheus `kube_deployment_status_replicas_unavailable` and `kube_pod_container_status_waiting_reason`, and alert-router decision logs.
