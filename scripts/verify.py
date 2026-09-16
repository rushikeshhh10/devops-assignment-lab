#!/usr/bin/env python3
"""
verify.py - Deployment verifier for the DevOps assignment lab.

What it checks, in order:
  1. Readiness: the WAF-fronted Juice Shop responds, and the Wazuh Indexer
     API responds.
  2. Sends one HTTP request through the WAF carrying a fresh, unique marker.
  3. Polls the Wazuh Indexer until that exact marker appears in an indexed
     alert - proving the full pipeline works: WAF -> Caddy access log ->
     Wazuh agent -> manager rule 100010 -> Indexer.

Exit codes (used by CI and the Terraform deployment gate):
  0 - success: readiness AND log delivery both confirmed
  1 - readiness check failed (app or indexer never became ready in time)
  2 - log delivery failed (marker never appeared in the Indexer in time)

Designed to run ON the App VM itself, since that's the only place with a
network path to both the public WAF endpoint (locally, via localhost) and
the Wazuh Indexer's private IP (permitted by the wazuh security group).

Usage:
  python3 verify.py \
      --app-url https://localhost/ \
      --indexer-url https://10.0.1.159:9200 \
      --indexer-user admin \
      --indexer-pass SecretPassword \
      --readiness-timeout 120 \
      --delivery-timeout 120
"""

import argparse
import base64
import ssl
import sys
import time
import uuid
import urllib.request


def make_ssl_context():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def http_get(url, timeout=10, user=None, password=None, ctx=None):
    req = urllib.request.Request(url, method="GET")
    if user is not None:
        creds = base64.b64encode(f"{user}:{password}".encode()).decode()
        req.add_header("Authorization", f"Basic {creds}")
    return urllib.request.urlopen(req, timeout=timeout, context=ctx)


def wait_until(name, check_fn, timeout_s, interval_s=3):
    deadline = time.time() + timeout_s
    last_err = None
    while time.time() < deadline:
        try:
            if check_fn():
                print(f"[READY] {name}")
                return True
        except Exception as e:
            last_err = e
        time.sleep(interval_s)
    print(f"[TIMEOUT] {name} did not succeed within {timeout_s}s. Last error: {last_err}", file=sys.stderr)
    return False


def main():
    p = argparse.ArgumentParser(description="Verify lab readiness and end-to-end log delivery.")
    p.add_argument("--app-url", required=True, help="Base URL of the WAF-fronted Juice Shop, e.g. https://localhost/")
    p.add_argument("--indexer-url", required=True, help="Wazuh Indexer base URL, e.g. https://10.0.1.159:9200")
    p.add_argument("--indexer-user", default="admin")
    p.add_argument("--indexer-pass", required=True)
    p.add_argument("--readiness-timeout", type=int, default=120)
    p.add_argument("--delivery-timeout", type=int, default=120)
    args = p.parse_args()

    ctx = make_ssl_context()

    # --- 1. Readiness checks ---
    def app_ready():
        with http_get(args.app_url, timeout=10, ctx=ctx) as resp:
            return resp.status == 200

    def indexer_ready():
        with http_get(args.indexer_url, timeout=10, user=args.indexer_user, password=args.indexer_pass, ctx=ctx) as resp:
            return resp.status == 200

    if not wait_until("Juice Shop / WAF", app_ready, args.readiness_timeout):
        sys.exit(1)
    if not wait_until("Wazuh Indexer", indexer_ready, args.readiness_timeout):
        sys.exit(1)

    # --- 2. Send a request carrying a fresh unique marker ---
    marker = f"verifier-{uuid.uuid4().hex}"
    marked_url = f"{args.app_url.rstrip('/')}/?verify={marker}"
    print(f"[INFO] Sending marker request: {marked_url}")
    try:
        with http_get(marked_url, timeout=15, ctx=ctx) as resp:
            print(f"[INFO] Marker request returned status {resp.status}")
    except Exception as e:
        print(f"[ERROR] Failed to send marker request: {e}", file=sys.stderr)
        sys.exit(1)

    # --- 3. Poll the Wazuh Indexer for the marker ---
    # Deliberately fetches recent alerts matched by our custom rule (100010,
    # see wazuh/caddy_rules.xml) and checks for the marker as a plain
    # substring, client-side - this sidesteps any uncertainty around how the
    # Indexer's analyzer tokenizes punctuation-heavy strings like a URL query
    # param, and mirrors the exact manual test that was already proven to
    # work end-to-end during Phase 4.
    search_url = f"{args.indexer_url.rstrip('/')}/wazuh-alerts-*/_search?q=rule.id:100010&sort=%40timestamp:desc&size=50"

    def marker_indexed():
        with http_get(search_url, timeout=10, user=args.indexer_user, password=args.indexer_pass, ctx=ctx) as resp:
            body = resp.read().decode()
            return marker in body

    if not wait_until(f"marker '{marker}' indexed in Wazuh", marker_indexed, args.delivery_timeout):
        print("[FAIL] Log delivery verification failed: marker never appeared in Wazuh Indexer.", file=sys.stderr)
        sys.exit(2)

    print(f"[SUCCESS] Marker '{marker}' confirmed in Wazuh Indexer. Full pipeline verified end-to-end.")
    sys.exit(0)


if __name__ == "__main__":
    main()
