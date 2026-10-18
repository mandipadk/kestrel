#!/usr/bin/env bash
# Kestrel, on the second exit (Chicago): copy the device list from Frankfurt,
# which is the authority. Run every minute by kestrel-devices.timer and by the
# Kestrel page right after a device is added, revoked or rotated. The list
# holds public keys only. A failed copy keeps the current list and exits 1.
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
