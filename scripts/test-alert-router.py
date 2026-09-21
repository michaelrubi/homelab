#!/usr/bin/env python3
"""Fail-open verification for the alert router.

Runs the router.py that actually ships (read out of the ConfigMap) against a
mock Jev and a mock ntfy. Every failure mode must still deliver the alert --
that is the property that separates this from receiver "null".

    python3 scripts/test-alert-router.py

Needs PyYAML. No cluster, no network, no API key."""
import json, os, subprocess, sys, threading, time, urllib.request, yaml
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SC = os.path.dirname(os.path.abspath(__file__))  # repo scripts/
MANIFEST = os.path.join(os.path.dirname(SC), "manifests", "infrastructure", "alert-router.yaml")

# Pull router.py straight out of the ConfigMap so we test what actually ships.
docs = [d for d in yaml.safe_load_all(open(MANIFEST)) if d]
src = [d for d in docs if d["kind"] == "ConfigMap"][0]["data"]["router.py"]
import tempfile
TMP = tempfile.mkdtemp()
open(f"{TMP}/router_under_test.py", "w").write(src)

DELIVERED = []
JEV_MODE = ["ok_suppress"]


class Mock(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0) or 0)
        raw = self.rfile.read(n)
        if self.path.startswith("/ntfy"):
            DELIVERED.append(raw)
            return self._j({"ok": True})
        mode = JEV_MODE[0]
        if mode == "http500":
            self.send_response(500); self.send_header("Content-Length", "0")
            self.end_headers(); return
        if mode == "timeout":
            time.sleep(6)  # router timeout is 3s
            return self._j({})
        if mode == "garbage":
            return self._j({"unexpected": "shape"})
        conf = {"ok_suppress": 0.99, "low_conf": 0.40, "ok_page": 0.97}[mode]
        choice = "page_now" if mode == "ok_page" else "suppress"
        self._j({"answers": {"disposition": {"choice": choice, "confidence": conf}}})

    def _j(self, o):
        b = json.dumps(o).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers()
        self.wfile.write(b)


srv = ThreadingHTTPServer(("127.0.0.1", 9901), Mock)
threading.Thread(target=srv.serve_forever, daemon=True).start()

env = {**os.environ,
       "JEV_URL": "http://127.0.0.1:9901/jev",
       "JEV_API_KEY": "test-key",
       "NTFY_URL": "http://127.0.0.1:9901/ntfy",
       "SUPPRESS_CONFIDENCE": "0.90",
       "JEV_TIMEOUT_SECONDS": "3",
       "DIGEST_INTERVAL_SECONDS": "99999"}
proc = subprocess.Popen([sys.executable, "-u", f"{TMP}/router_under_test.py"],
                        env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                        text=True)
time.sleep(1.5)

ALERT = {"status": "firing", "alerts": [{"status": "firing",
         "labels": {"alertname": "PodPendingTooLong", "severity": "warning",
                    "namespace": "default"},
         "annotations": {"summary": "pod stuck", "description": "wedged on a volume"}}]}


def send(payload=ALERT, body=None, wait=9.0):
    before = len(DELIVERED)
    urllib.request.urlopen(urllib.request.Request(
        "http://127.0.0.1:8080/",
        body if body is not None else json.dumps(payload).encode(),
        {"Content-Type": "application/json"}), timeout=20).read()
    # Poll past the router's 3s Jev timeout so a late page is not attributed
    # to the next case. Settle briefly afterwards to catch a stray delivery.
    deadline = time.time() + wait
    while time.time() < deadline and len(DELIVERED) == before:
        time.sleep(0.1)
    time.sleep(0.4)
    return len(DELIVERED) > before


CASES = [
    ("Jev says suppress, high confidence", "ok_suppress", False, "suppressed"),
    ("Jev says page_now",                  "ok_page",     True,  "paged"),
    ("Jev says suppress, LOW confidence",  "low_conf",    True,  "paged (below threshold)"),
    ("Jev returns HTTP 500",               "http500",     True,  "paged (fail-open)"),
    ("Jev times out",                      "timeout",     True,  "paged (fail-open)"),
    ("Jev returns garbage shape",          "garbage",     True,  "paged (fail-open)"),
]

print(f"\n{'scenario':<38} {'expected':<26} result")
print("-" * 82)
bad = 0
for name, mode, want_page, expl in CASES:
    JEV_MODE[0] = mode
    got = send()
    ok = got == want_page
    bad += not ok
    print(f"{name:<38} {expl:<26} {'ok' if ok else 'FAIL (delivered=%s)' % got}")

# Unparseable body must also forward.
JEV_MODE[0] = "ok_suppress"
ok = send(body=b"this is not json")
bad += not ok
print(f"{'Unparseable webhook body':<38} {'paged (fail-open)':<26} {'ok' if ok else 'FAIL'}")

m = urllib.request.urlopen("http://127.0.0.1:8080/metrics", timeout=5).read().decode()
print("\n--- /metrics ---")
for line in m.splitlines():
    if line and not line.startswith("#"):
        print("   " + line)

proc.terminate()
print(f"\n{len(CASES)+1-bad}/{len(CASES)+1} passed")
sys.exit(1 if bad else 0)
