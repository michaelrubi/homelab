#!/usr/bin/env bash
# Connectivity matrix for manifests/infrastructure/network-policies.yaml.
#
# For each client label, starts a throwaway busybox pod in `default` wearing
# that label and tries TCP connects to the listed Services. Prints one line
# per check and exits non-zero if any result differs from what the policies
# intend. Run it after any change to the policies:
#
#   scripts/netpol-check.sh
#
# The probe pods carry real app labels (app=n8n, app=postiz...), which the
# app's own Service also selects. Their readiness probe always fails, so they
# never become endpoints and no real traffic is sent to them.
set -euo pipefail

NS=default
fail=0

# client-label  target:port ...  (+ means allowed, - means blocked)
MATRIX=(
  "netpol-probe     -postgres:5432 -kaneo-postgres:5432 -postiz-postgres:5432 -postiz-temporal-postgres:5432 -postiz-redis:6379 -postiz-temporal:7233 -postiz-temporal-elasticsearch:9200 -forgejo-service:3000 -n8n-service:5678 -vaultwarden-service:8080 -stalwart-http:8080 +stalwart-mail:25 +stalwart-mail:465 -stalwart-mail:993"
  "n8n              +postgres:5432 +forgejo-service:3000 +kaneo-service:5173 +postiz-service:5000 +stalwart-http:8080 -vaultwarden-service:8080 -obsidian-sync-service:5984 -kaneo-postgres:5432"
  "postgres-backup  +postgres:5432 +kaneo-postgres:5432 +postiz-postgres:5432 +postiz-temporal-postgres:5432 -forgejo-service:3000"
  "renovate         +forgejo-service:3000 -postgres:5432"
  "forgejo-runner   +forgejo-service:3000 -n8n-service:5678"
  "forgejo          +n8n-service:5678 -postgres:5432"
  "pgweb            +postgres:5432 -postiz-postgres:5432"
  "postiz           +postiz-postgres:5432 +postiz-redis:6379 +postiz-temporal:7233 -kaneo-postgres:5432"
  "postiz-temporal  +postiz-temporal-postgres:5432 +postiz-temporal-elasticsearch:9200 +postiz-temporal:7233"
  "kaneo            +kaneo-postgres:5432 -postiz-postgres:5432"
  "torrenter        +jackett-service:9117 -postgres:5432"
)

for row in "${MATRIX[@]}"; do
  read -r label checks <<<"$row"
  script='sleep 4'  # a new pod is blocked until kube-router learns its IP
  for c in $checks; do
    want=${c:0:1} target=${c:1}
    script+="; if nc -z -w 3 ${target%:*} ${target#*:}; then echo \"$want $target open\"; else echo \"$want $target closed\"; fi"
  done
  overrides=$(cat <<EOF
{"spec":{"containers":[{"name":"p","image":"busybox:1.37","command":["sh","-c","$(sed 's/"/\\"/g' <<<"$script")"],
 "readinessProbe":{"exec":{"command":["false"]},"periodSeconds":60},
 "resources":{"requests":{"cpu":"5m","memory":"8Mi"},"limits":{"memory":"32Mi"}}}]}}
EOF
)
  while read -r want target state; do
    [[ -z "${want:-}" ]] && continue
    if [[ ($want == + && $state == open) || ($want == - && $state == closed) ]]; then
      printf '  ok   %-16s %s %s\n' "$label" "$state" "$target"
    else
      printf 'FAIL   %-16s %s %s (expected %s)\n' "$label" "$state" "$target" \
        "$([[ $want == + ]] && echo open || echo closed)"
      fail=1
    fi
  done < <(kubectl -n "$NS" run "netpol-check-$label" --labels="app=$label" \
             --restart=Never --rm -i --quiet --image=busybox:1.37 \
             --overrides="$overrides" 2>/dev/null | grep -E '^[+-] ')
done

exit $fail
