#!/usr/bin/env bash
# Kestrel disguised-link test: a device on a network that blocks its exit.
#
#   disguise-test.sh <client> <exit city> <disguised url> [--expect-fail]
#
# The device is given its exit with the real key but an address nothing
# answers on (192.0.2.1, as if the network dropped the exit's address), plus
# the exit's disguised address. Automatic mode must load pages and a download
# through the disguise. Also: always-disguised works with the real address;
# direct-only fails (so the blackhole is real); a stranger's key is refused
# over the disguise; the edge answers 404 to anything but its path.
# --expect-fail: a control run with an engine from before the disguised link,
# which must fail the automatic check.
set -uo pipefail
CLIENT=${1:?usage: disguise-test.sh <client> <city> <url> [--expect-fail]}
CITY=${2:?}
URL=${3:?}
CONTROL=${4:-}
STATE=/var/lib/kestrel
WORK=$(mktemp -d)
PIDS=()
pass=0 fail=0
ok() { echo "ok    $*"; pass=$((pass + 1)); }
bad() { echo "FAIL  $*"; fail=$((fail + 1)); }
cleanup() { for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; wait 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }

# config <name> <endpoint> <link> [stranger] -> socks port
config() {
  local name=$1 endpoint=$2 link=$3 stranger=${4:-} port
  port=$(free_port)
  python3 - "$STATE/probe.yaml" "$STATE/exits.json" "$CITY" "$endpoint" "$link" "$URL" "$port" "$stranger" > "$WORK/$name.yaml" <<'PY'
import json, secrets, sys, yaml
probe, exits, city, endpoint, link, url, port, stranger = sys.argv[1:]
cfg = yaml.safe_load(open(probe))
target = dict(next(e for e in json.load(open(exits)) if e["city"] == city))
real = target["endpoint"]
target["endpoint"] = real if endpoint == "real" else endpoint
target["disguise"] = url
dev = cfg["kestrel_device"]
dev.update(exits=[target], exit_choice=city, stealth=True)
if link != "auto":
    dev["link"] = link
if stranger:
    dev["secret"] = secrets.token_hex(32)
cfg["exit_constraint"] = {"direct": f'{target["endpoint"]}/{target["pubkey"]}'}
cfg["socks5_listen"] = f"127.0.0.1:{port}"
for k in ("http_proxy_listen", "control_listen", "vpn"):
    cfg.pop(k, None)
print(yaml.safe_dump(cfg))
PY
  "$CLIENT" --config "$WORK/$name.yaml" > "$WORK/$name.log" 2>&1 &
  PIDS+=($!)
  echo "$port"
}

# works <port> <seconds> -> prints the address sites see, fails if nothing came
works() {
  local port=$1 until=$(( $(date +%s) + $2 )) out
  while (( $(date +%s) < until )); do
    out=$(curl -s --max-time 8 --socks5-hostname "127.0.0.1:$port" https://1.1.1.1/cdn-cgi/trace 2>/dev/null) || true
    if grep -q '^ip=' <<<"$out"; then sed -n 's/^ip=//p' <<<"$out"; return 0; fi
    sleep 1
  done
  return 1
}

EXIT_IP=$(python3 -c 'import json,sys; print(next(e for e in json.load(open(sys.argv[1])) if e["city"]==sys.argv[2])["endpoint"].rsplit(":",1)[0])' "$STATE/exits.json" "$CITY")
echo "Kestrel disguised-link test: $CITY ($EXIT_IP) through $(sed -E 's#(://[^/]+/).*#\1…#' <<<"$URL")"

# 1. the exit's address is blocked; automatic must get through disguised
P=$(config blocked 192.0.2.1:443 auto)
start=$(date +%s)
if ip=$(works "$P" 40); then
  if [[ $CONTROL == --expect-fail ]]; then
    bad "control: an engine without the disguised link got through ($ip)"
  elif [[ $ip == "$EXIT_IP" ]]; then
    ok "address blocked: automatic got through disguised in $(( $(date +%s) - start )) s, sites see $ip"
  else
    bad "address blocked: sites see $ip, not the exit"
  fi
else
  if [[ $CONTROL == --expect-fail ]]; then
    ok "control: an engine without the disguised link can't get through"
    echo "$pass passed, $fail failed"
    exit $(( fail > 0 ))
  fi
  bad "address blocked: automatic did not get through (log: $(grep -iE 'disguis|error|fail' "$WORK/blocked.log" | tail -2))"
fi
bytes=$(curl -s --max-time 60 --socks5-hostname "127.0.0.1:$P" -o /dev/null -w '%{size_download} %{speed_download}' 'https://speed.cloudflare.com/__down?bytes=10000000' || true)
read -r size speed <<<"$bytes"
if [[ ${size:-0} == 10000000 ]]; then
  ok "10 MB download through the disguise at $(python3 -c "print(round(${speed}*8/1e6))") Mbit/s"
else
  bad "10 MB download through the disguise (got ${size:-0} bytes)"
fi
for page in https://example.com/ https://www.wikipedia.org/ https://github.com/; do
  code=$(curl -s --max-time 20 --socks5-hostname "127.0.0.1:$P" -o /dev/null -w '%{http_code}' "$page" || true)
  [[ $code =~ ^(200|301|302)$ ]] && ok "page through the disguise: $page ($code)" || bad "page through the disguise: $page ($code)"
done

# 2. always disguised, with the real address
P=$(config always real disguised)
ip=$(works "$P" 30) && [[ $ip == "$EXIT_IP" ]] && ok "always disguised: sites see $ip" || bad "always disguised did not get through"

# 3. direct only, address blocked: must fail (the blackhole is real)
P=$(config direct 192.0.2.1:443 direct)
if works "$P" 20 >/dev/null; then bad "direct-only got through a blocked address?"; else ok "direct-only can't reach a blocked address (the block is real)"; fi

# 4. a stranger's key over the disguise
P=$(config stranger real disguised yes)
if works "$P" 20 >/dev/null; then bad "a stranger's key got through the disguise"; else ok "a stranger's key is refused over the disguise"; fi

# 5. the edge shows nothing but 404s
base=$(sed -E 's#^wss?://([^/]+)/.*#\1#' <<<"$URL")
scheme=https; [[ $URL == ws://* ]] && scheme=http
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$scheme://$base/")
[[ $code == 404 ]] && ok "the edge's front page is a 404" || bad "the edge's front page answered $code"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
  -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' "$scheme://$base/k/guess")
[[ $code == 404 ]] && ok "a WebSocket to a guessed path is a 404" || bad "a WebSocket to a guessed path answered $code"

echo "$pass passed, $fail failed"
exit $(( fail > 0 ))
