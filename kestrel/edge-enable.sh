#!/usr/bin/env bash
# Kestrel: turn the disguised link on (run once, on Chicago, as ubuntu).
#
#   edge-enable.sh
#
# 1. Puts each exit's edge online as a public address (launch --public):
#    kestrel-edge.mandip.dev on Chicago, kestrel-edge-fra.mandip.dev on
#    Frankfurt. Each answers 404 to anything but its secret path
#    (~/.config/kestrel/edge-path on that server) and only forwards to its own
#    exit, which still checks every device's key.
# 2. Adds each address to both exits' /var/lib/kestrel/exits.json, so devices
#    learn it from their next report.
# 3. Proves it: disguise-test.sh against each live address (a blackholed exit
#    address must still load pages through the disguise).
set -euo pipefail
K=$(cd "$(dirname "$0")" && pwd)
EDGE=$HOME/sites/kestrel-edge

launch "$EDGE" --name kestrel-edge --public --cmd "npm start"
launch "$EDGE" --name kestrel-edge-fra --public --server frankfurt --cmd "npm start"

CHI="wss://kestrel-edge.mandip.dev$(cat ~/.config/kestrel/edge-path)"
FRA="wss://kestrel-edge-fra.mandip.dev$(ssh frankfurt cat .config/kestrel/edge-path)"

# give both addresses a moment to answer
for host in kestrel-edge.mandip.dev kestrel-edge-fra.mandip.dev; do
  for _ in $(seq 30); do
    [[ $(curl -s -o /dev/null -w '%{http_code}' "https://$host/") == 404 ]] && break
    sleep 2
  done
done

update='import json, os, sys
path, chi, fra = sys.argv[1:]
exits = json.load(open(path))
for e in exits:
    e["disguise"] = {"Chicago": chi, "Frankfurt": fra}[e["city"]]
tmp = path + ".tmp"
json.dump(exits, open(tmp, "w"), indent=2)
os.chmod(tmp, 0o640)
os.replace(tmp, path)'
sg kestrel -c "python3 -c '$update' /var/lib/kestrel/exits.json '$CHI' '$FRA'"
ssh frankfurt "python3 -c '$update' /var/lib/kestrel/exits.json '$CHI' '$FRA'"
echo "exits.json on both exits now carries the disguised addresses"

ssh frankfurt "~/code/kestrel/kestrel/disguise-test.sh /opt/kestrel/current/geph5-client Frankfurt '$FRA'"
sg kestrel -c "$K/disguise-test.sh /opt/kestrel/current/geph5-client Chicago '$CHI'"
