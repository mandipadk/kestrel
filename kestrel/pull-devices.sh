#!/usr/bin/env bash
# Kestrel, on the second exit (Chicago): copy the device list from Frankfurt,
# which is the authority, and merge Shield's allow lists both ways. Run every minute by
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

# Shield's allow lists: devices allow domains on whichever exit they use, so
# merge both ways (the exits reload the files when they change)
python3 "$(dirname "$0")/allow-sync.py" /var/lib/kestrel /var/lib/kestrel/allow-sync-base.json
