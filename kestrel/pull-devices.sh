#!/usr/bin/env bash
# Kestrel, on the second exit (Chicago): copy the device list and the Shield
# allow list from Frankfurt, which is the authority. Run every minute by
# kestrel-devices.timer and by the Kestrel page right after a device or the
# allow list changes. The device list holds public keys only. A failed copy
# keeps the current lists and exits 1.
set -euo pipefail
DEST=/var/lib/kestrel/devices.json
TMP=$(mktemp /var/lib/kestrel/.devices.XXXXXX)
trap 'rm -f "$TMP"' EXIT
ssh -o BatchMode=yes -o ConnectTimeout=8 frankfurt cat /var/lib/kestrel/devices.json > "$TMP"
python3 - "$TMP" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert isinstance(d.get("devices"), list), "no device list"
for e in d["devices"]:
    assert isinstance(e["name"], str) and len(e["pubkey"]) == 64 and isinstance(e["revoked"], bool)
PY
if ! cmp -s "$TMP" "$DEST"; then
  chmod 0660 "$TMP"
  mv -f "$TMP" "$DEST"
  echo "device list updated ($(python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["devices"]; print(sum(not x["revoked"] for x in d), "active,", sum(x["revoked"] for x in d), "revoked")' "$DEST"))"
fi

# the domains Shield never blocks (the exit reloads the file when it changes)
ALLOW=/var/lib/kestrel/shield-allow.txt
ssh -o BatchMode=yes -o ConnectTimeout=8 frankfurt 'cat /var/lib/kestrel/shield-allow.txt 2>/dev/null || true' > "$TMP"
if ! cmp -s "$TMP" "$ALLOW" 2>/dev/null; then
  chmod 0660 "$TMP"
  cp -f "$TMP" "$ALLOW.new" && mv -f "$ALLOW.new" "$ALLOW"
  echo "allow list updated ($(grep -cv '^\s*\(#\|$\)' "$ALLOW" || true) domains)"
fi
