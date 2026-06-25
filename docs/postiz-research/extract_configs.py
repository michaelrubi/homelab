#!/usr/bin/env python3
"""Extract specific configs from layer 9 + 10."""
import json
import urllib.request
import io
import tarfile

REPO = "gitroomhq/postiz-app"
BASE = "https://ghcr.io"

def http_get_json(url, token, accept):
    req = urllib.request.Request(url, headers={
        "Authorization": f"Bearer {token}",
        "Accept": accept,
    })
    with urllib.request.urlopen(req) as r:
        return json.loads(r.read())

tok = http_get_json(
    f"{BASE}/token?service=ghcr.io&scope=repository:{REPO}:pull",
    token="", accept="application/json",
)["token"]
idx = http_get_json(
    f"{BASE}/v2/{REPO}/manifests/latest", tok,
    accept="application/vnd.oci.image.index.v1+json",
)
amd = next(m for m in idx["manifests"] if m["platform"]["architecture"] == "amd64")
man = http_get_json(
    f"{BASE}/v2/{REPO}/manifests/{amd['digest']}", tok,
    accept="application/vnd.oci.image.manifest.v1+json",
)
layers = man["layers"]

def fetch_blob(digest):
    req = urllib.request.Request(
        f"{BASE}/v2/{REPO}/blobs/{digest}",
        headers={"Authorization": f"Bearer {tok}", "Accept": "*/*"},
    )
    with urllib.request.urlopen(req) as r:
        return r.read()

# Specific file targets
TARGETS = {
    "app/package.json": None,
    "app/Dockerfile.dev": None,
    "app/pnpm-workspace.yaml": None,
    "app/apps/backend/package.json": None,
    "app/apps/frontend/package.json": None,
    "app/apps/orchestrator/package.json": None,
    "app/apps/commands/package.json": None,
    "etc/nginx/nginx.conf": None,
}

print("downloading layers 9 + 10...")
blob9 = fetch_blob(layers[9]["digest"])
blob10 = fetch_blob(layers[10]["digest"])
print("done")

for label, blob in [("layer 9", blob9), ("layer 10", blob10)]:
    with tarfile.open(fileobj=io.BytesIO(blob), mode="r:*") as tf:
        for m in tf.getmembers():
            if m.name in TARGETS:
                f = tf.extractfile(m)
                if f:
                    content = f.read().decode("utf-8", errors="replace")
                    TARGETS[m.name] = content
                    print(f"\n========== {label} :: {m.name} ({len(content)} bytes) ==========")
                    print(content[:6000])
                    print("[...]" if len(content) > 6000 else "")

# print any remaining unset ones
for k in TARGETS:
    if TARGETS[k] is None:
        print(f"NOT FOUND: {k}")