#!/usr/bin/env bash
# Kestrel: a device's Shield allow reaches both exits (run on Frankfurt).
#
#   allow-live-test.sh
#
# The lockdown probe, pinned to Chicago, allows a blocked domain for itself
# through its tunnel; after Chicago's next device sync (every minute) the
# Frankfurt exit lets it through for the probe and no one else; undoing it
# through Frankfurt reaches Chicago the same way.
set -uo pipefail
STATE=/var/lib/kestrel
CLIENT=/opt/kestrel/current/geph5-client
DOMAIN=stats.g.doubleclick.net
WORK=$(mktemp -d)
PIDS=()
pass=0 fail=0
ok() { echo "ok    $*"; pass=$((pass + 1)); }
bad() { echo "FAIL  $*"; fail=$((fail + 1)); }
cleanup() { for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; wait 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }

# client <city> -> socks port of the probe pinned to that exit
client() {
  local city=$1 port
  port=$(free_port)
  python3 - "$STATE/probe.yaml" "$STATE/exits.json" "$city" "$port" > "$WORK/$city.yaml" <<'PY'
import json, sys, yaml
cfg = yaml.safe_load(open(sys.argv[1]))
target = next(e for e in json.load(open(sys.argv[2])) if e["city"] == sys.argv[3])
if target["endpoint"].startswith("92.5.139.56:"):  # this host's own exit, over loopback
    target = dict(target, endpoint="127.0.0.1:443")
dev = cfg["kestrel_device"]
dev.update(exits=[target], exit_choice=sys.argv[3], stealth=True)
cfg["exit_constraint"] = {"direct": f'{target["endpoint"]}/{target["pubkey"]}'}
cfg["socks5_listen"] = f"127.0.0.1:{sys.argv[4]}"
for k in ("http_proxy_listen", "control_listen", "pac_listen", "vpn"):
    cfg.pop(k, None)
print(yaml.safe_dump(cfg))
PY
  "$CLIENT" --config "$WORK/$city.yaml" > "$WORK/$city.log" 2>&1 &
  PIDS+=($!)
  for _ in $(seq 20); do
    curl -s --max-time 5 --socks5-hostname "127.0.0.1:$port" https://1.1.1.1/cdn-cgi/trace >/dev/null 2>&1 && break
    sleep 1
  done
  echo "$port"
}

# ask <port> <request> -> the exit's report (JSON) for that device
ask() {
  curl -s --http0.9 --max-time 15 --socks5-hostname "127.0.0.1:$1" "http://$2.kestrel.internal:1/" 2>/dev/null
}

# reaches <port> -> 0 if an HTTPS request by name to the domain gets an answer
# (Shield refuses blocked names at the exit, so the SOCKS connect fails)
reaches() {
  curl -s -o /dev/null --max-time 10 --socks5-hostname "127.0.0.1:$1" "https://$DOMAIN/" 2>/dev/null
}

allowed_in() { # allowed_in <report json> -> 0 if DOMAIN is in this device's allow list
  python3 -c 'import json,sys; r=json.loads(sys.argv[1]); sys.exit(0 if sys.argv[2] in r["shield"].get("allowed",[]) else 1)' "$1" "$DOMAIN" 2>/dev/null
}

wait_merge() { # until the probe's allow list on <city> agrees with <want: yes|no>
  local port=$1 want=$2
  for _ in $(seq 20); do
    r=$(ask "$port" status)
    if allowed_in "$r"; then [[ $want == yes ]] && return 0; else [[ $want == no ]] && return 0; fi
    sleep 6
  done
  return 1
}

echo "Kestrel allow test: a device allows $DOMAIN on Chicago; Frankfurt follows"
CHI=$(client Chicago)
FRA=$(client Frankfurt)
reaches "$FRA" && bad "Frankfurt let $DOMAIN through before the allow" || ok "Frankfurt blocks $DOMAIN to start with"

r=$(ask "$CHI" "shield-allow.$DOMAIN")
allowed_in "$r" && ok "Chicago took the allow (the report lists it)" || bad "Chicago did not take the allow: ${r:0:200}"
reaches "$CHI" && ok "Chicago lets $DOMAIN through for this device" || bad "Chicago still blocks $DOMAIN"

wait_merge "$FRA" yes && ok "Frankfurt has the allow after the sync" || bad "Frankfurt never got the allow"
reaches "$FRA" && ok "Frankfurt lets $DOMAIN through for this device" || bad "Frankfurt still blocks $DOMAIN"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if all(sys.argv[2] not in v for k,v in d.items() if k!="lockdown-probe") else 1)' \
  "$STATE/shield-allow-devices.json" "$DOMAIN" && ok "no other device got the allow" || bad "another device got the allow"

r=$(ask "$FRA" "shield-unallow.$DOMAIN")
allowed_in "$r" && bad "Frankfurt kept the allow after undo" || ok "undone on Frankfurt"
wait_merge "$CHI" no && ok "Chicago dropped it after the sync" || bad "Chicago kept the allow"
reaches "$CHI" && bad "Chicago still lets $DOMAIN through" || ok "Chicago blocks $DOMAIN again"

echo "$pass passed, $fail failed"
exit $(( fail > 0 ))
