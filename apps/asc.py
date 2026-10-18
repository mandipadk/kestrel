#!/usr/bin/env python3
"""Small App Store Connect API helper for CI.

    asc.py bundle <identifier>                 show a bundle ID's platform and capabilities
    asc.py capability <identifier> <TYPE>      make sure a capability is on (e.g. ACCESS_WIFI_INFORMATION)

Reads ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH (the .p8 file). Needs PyJWT
with its crypto extra.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request

import jwt

API = "https://api.appstoreconnect.apple.com/v1"


def token():
    key = open(os.environ["ASC_KEY_PATH"]).read()
    now = int(time.time())
    return jwt.encode(
        {"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"},
        key,
        algorithm="ES256",
        headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"},
    )


def call(method, path, body=None):
    req = urllib.request.Request(
        API + path,
        method=method,
        data=json.dumps(body).encode() if body else None,
        headers={"Authorization": f"Bearer {token()}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")


def bundle(identifier):
    status, out = call("GET", f"/bundleIds?filter[identifier]={identifier}&include=bundleIdCapabilities")
    if status != 200:
        sys.exit(f"cannot read bundle IDs ({status}): {out}")
    match = [b for b in out["data"] if b["attributes"]["identifier"] == identifier]
    if not match:
        sys.exit(f"no bundle ID {identifier}")
    caps = sorted(i["attributes"]["capabilityType"] for i in out.get("included", []) if i["type"] == "bundleIdCapabilities")
    return match[0], caps


def main():
    if len(sys.argv) >= 3 and sys.argv[1] == "bundle":
        b, caps = bundle(sys.argv[2])
        print(f"{sys.argv[2]}: platform {b['attributes']['platform']}, capabilities {', '.join(caps) or 'none'}")
    elif len(sys.argv) >= 4 and sys.argv[1] == "capability":
        b, caps = bundle(sys.argv[2])
        if sys.argv[3] in caps:
            print(f"{sys.argv[2]} already has {sys.argv[3]}")
            return
        status, out = call("POST", "/bundleIdCapabilities", {"data": {
            "type": "bundleIdCapabilities",
            "attributes": {"capabilityType": sys.argv[3]},
            "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": b["id"]}}},
        }})
        if status not in (200, 201):
            sys.exit(f"could not turn on {sys.argv[3]} ({status}): {out}")
        print(f"turned on {sys.argv[3]} for {sys.argv[2]}")
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
