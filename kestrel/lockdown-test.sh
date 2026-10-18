#!/usr/bin/env bash
# Kestrel lockdown test.
#
#   lockdown-test.sh <bin-dir>          start a throwaway exit from <bin-dir> on
#                                       localhost and prove only enrolled,
#                                       unrevoked devices get through
#   lockdown-test.sh --live             probe the running geph-exit service
#
# Exits non-zero on the first failed check.
set -uo pipefail

PASS=0
FAIL=0
ok()   { echo "  ok    $*"; PASS=$((PASS + 1)); }
bad()  { echo "  FAIL  $*"; FAIL=$((FAIL + 1)); }

WORK=$(mktemp -d /tmp/kestrel-lockdown.XXXXXX)
PIDS=()
cleanup() {
  for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done
  pkill -f "$WORK/" 2>/dev/null
  wait 2>/dev/null
  [[ -n ${KEEP:-} ]] && echo "kept $WORK" || rm -rf "$WORK"
}
trap cleanup EXIT

free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])'; }

# start_client <name> <config-file> -> echoes socks port
start_client() {
  local name=$1 cfg=$2 port ctl
  port=$(free_port); ctl=$(free_port)
  python3 - "$cfg" "$port" "$ctl" > "$WORK/$name.run.yaml" <<'PY'
import sys, yaml
cfg = yaml.safe_load(open(sys.argv[1]))
cfg["socks5_listen"] = f"127.0.0.1:{sys.argv[2]}"
cfg["http_proxy_listen"] = None
cfg["pac_listen"] = None
cfg["control_listen"] = f"127.0.0.1:{sys.argv[3]}"
print(yaml.safe_dump(cfg))
PY
  "$CLIENT" --config "$WORK/$name.run.yaml" > "$WORK/$name.log" 2>&1 &
  echo "$port"
}

# through <socks-port> <url> -> prints body, fails if unreachable
through() {
  curl -sS --max-time "${3:-25}" --socks5-hostname "127.0.0.1:$1" "$2"
}

expect_works() {
  local what=$1 port=$2 out
  for _ in 1 2 3; do
    out=$(through "$port" https://1.1.1.1/cdn-cgi/trace 2>/dev/null) && break
    sleep 3
  done
  if grep -q '^ip=' <<<"$out"; then ok "$what ($(grep '^ip=' <<<"$out"))"; else bad "$what"; fi
}

expect_refused() {
  local what=$1 port=$2
  if through "$port" https://1.1.1.1/cdn-cgi/trace 15 >/dev/null 2>&1; then
    bad "$what: got through"
  else
    ok "$what"
  fi
}

make_config() { # make_config <name> <out> using $CTL against $DEVICES
  "$CTL" --devices "$DEVICES" --signing-secret "$SECRET" --endpoint "$ENDPOINT" add "$1" --out "$2" >/dev/null
}

if [[ "${1:-}" == "--live" ]]; then
  BIN=/opt/kestrel/current
  CLIENT=$BIN/geph5-client
  CTL=$BIN/kestrelctl
  DEVICES=/var/lib/kestrel/devices.json
  SECRET=/var/lib/kestrel/signing.key
  ENDPOINT=127.0.0.1:443
  echo "Kestrel lockdown test (live service)"
  systemctl is-active --quiet geph-exit && ok "geph-exit is running" || bad "geph-exit is not running"
  # the probe device lives in the real device list; its key is kept locally
  PROBE=/var/lib/kestrel/probe.yaml
  if [[ ! -s $PROBE ]]; then
    "$CTL" --devices "$DEVICES" --signing-secret "$SECRET" --endpoint "$ENDPOINT" rotate lockdown-probe --out "$PROBE" >/dev/null 2>&1 \
      || make_config lockdown-probe "$PROBE"
  fi
  sed "s#direct: .*/#direct: $ENDPOINT/#" "$PROBE" > "$WORK/probe.yaml"
else
  BIN=${1:?usage: lockdown-test.sh <bin-dir> | --live}
  CLIENT=$BIN/geph5-client
  CTL=$BIN/kestrelctl
  DEVICES=$WORK/devices.json
  SECRET=$WORK/signing.key
  PORT=$(free_port)
  ENDPOINT=127.0.0.1:$PORT
  echo "Kestrel lockdown test (throwaway exit on $ENDPOINT)"
  head -c 32 /dev/urandom > "$SECRET"
  echo '{"devices":[]}' > "$DEVICES"
  make_config lockdown-probe "$WORK/probe.yaml"
  cat > "$WORK/exit.yaml" <<EOF
signing_secret: $SECRET
c2e_listen: $ENDPOINT
b2e_listen: 127.0.0.1:$(free_port)
country: DE
city: Frankfurt
kestrel_devices: $DEVICES
kestrel_status: $WORK/status.json
EOF
  # an exit with no broker and no device list must refuse to start
  grep -v kestrel_devices "$WORK/exit.yaml" > "$WORK/open-exit.yaml"
  if timeout 5 "$BIN/geph5-exit" --config "$WORK/open-exit.yaml" >/dev/null 2>&1; then
    bad "an exit without a device list started"
  else
    ok "an exit without a device list refuses to start"
  fi
  "$BIN/geph5-exit" --config "$WORK/exit.yaml" > "$WORK/exit.log" 2>&1 &
  EXIT_PID=$!
  PIDS+=($EXIT_PID)
  sleep 2
  if ! kill -0 "$EXIT_PID" 2>/dev/null; then
    bad "test exit did not start: $(tail -1 "$WORK/exit.log")"
    exit 1
  fi
fi

if [[ ! -s "$WORK/probe.yaml" ]] || ! grep -q kestrel_device "$WORK/probe.yaml"; then
  bad "could not prepare the probe device config"
  exit 1
fi

# 1. an enrolled device gets through
P=$(start_client probe "$WORK/probe.yaml")
expect_works "enrolled device connects" "$P"

# 1b. abuse limits for an enrolled device
if curl -sS --max-time 8 --socks5-hostname "127.0.0.1:$P" telnet://127.0.0.1:22 </dev/null 2>&1 | grep -q "SSH-"; then
  bad "enrolled device reached the exit host loopback"
else
  ok "loopback and private addresses are unreachable through the exit"
fi
if curl -sS --max-time 10 --socks5-hostname "127.0.0.1:$P" telnet://smtp.gmail.com:587 </dev/null 2>&1 | grep -qi "220"; then
  bad "SMTP submission reachable"
else
  ok "SMTP (25/465/587/2525) is blocked"
fi

# 2. no credential at all (a stock Geph client pointed at this exit)
python3 - "$WORK/probe.yaml" > "$WORK/nokey.cfg" <<'PY'
import sys, yaml
cfg = yaml.safe_load(open(sys.argv[1]))
cfg.pop("kestrel_device")
print(yaml.safe_dump(cfg))
PY
P=$(start_client nokey "$WORK/nokey.cfg")
expect_refused "client without a device key is refused" "$P"

# 3. a well-formed key the exit has never seen
python3 - "$WORK/probe.yaml" > "$WORK/stranger.cfg" <<'PY'
import sys, yaml, secrets
cfg = yaml.safe_load(open(sys.argv[1]))
cfg["kestrel_device"]["secret"] = secrets.token_hex(32)
print(yaml.safe_dump(cfg))
PY
P=$(start_client stranger "$WORK/stranger.cfg")
expect_refused "unknown device key is refused" "$P"

# 4. a revoked device (local mode only: never revoke real devices from a test)
if [[ "${1:-}" != "--live" ]]; then
  make_config retired "$WORK/retired.yaml"
  "$CTL" --devices "$DEVICES" --signing-secret "$SECRET" revoke retired >/dev/null
  P=$(start_client retired "$WORK/retired.yaml")
  expect_refused "revoked device is refused" "$P"
fi

# 5. junk on the port gets nothing back
reply=$(head -c 64 /dev/urandom | timeout 12 nc -w 10 "${ENDPOINT%:*}" "${ENDPOINT##*:}" 2>/dev/null | head -c 16 | wc -c)
[[ "$reply" == 0 ]] && ok "raw junk gets no reply" || bad "raw junk got $reply bytes back"

# with_link <config> <stealth: true|false> -> a copy of the config on that link
with_link() {
  python3 - "$1" "$2" <<'PY'
import sys, yaml
cfg = yaml.safe_load(open(sys.argv[1]))
cfg["kestrel_device"]["stealth"] = sys.argv[2] == "true"
print(yaml.safe_dump(cfg))
PY
}

# ask <socks-port> <request> -> the exit's JSON report about this device
ask() {
  curl -sS --max-time 15 --socks5-hostname "127.0.0.1:$1" "telnet://$2.kestrel.internal:1" </dev/null 2>/dev/null
}

# field <json> <python expression on d> -> prints the value
field() { python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(eval(sys.argv[2]))' "$1" "$2" 2>/dev/null; }

# 6. both links work: stealth (sosistab3) and plain
with_link "$WORK/probe.yaml" true > "$WORK/stealth.cfg"
STEALTH=$(start_client stealth "$WORK/stealth.cfg")
expect_works "enrolled device connects over the stealth link" "$STEALTH"
report=$(ask "$STEALTH" status)
[[ $(field "$report" 'd["stealth"]') == True ]] && ok "the exit sees the stealth link" || bad "stealth link not seen: $report"
with_link "$WORK/probe.yaml" false > "$WORK/plain.cfg"
PLAIN=$(start_client plain "$WORK/plain.cfg")
expect_works "enrolled device connects over the plain link" "$PLAIN"

# 7. the in-tunnel report: only this device's own facts
[[ $(field "$report" 'd["device"]') == lockdown-probe ]] && ok "the device gets its own report through the tunnel" || bad "report: $report"
if curl -sS --max-time 8 "http://${ENDPOINT%:*}:${ENDPOINT##*:}/" -H "Host: status.kestrel.internal" 2>/dev/null | grep -q device; then
  bad "the report is reachable without a tunnel"
else
  ok "the report is unreachable without a tunnel"
fi

# 8. Shield: a tracker is refused, an ordinary site is not, and it counts
before=$(field "$report" 'd["shield"]["blocked_total"]')
if curl -sS --max-time 10 --socks5-hostname "127.0.0.1:$STEALTH" -o /dev/null https://stats.g.doubleclick.net/ 2>/dev/null; then
  bad "Shield let a tracker through"
else
  after=$(field "$(ask "$STEALTH" status)" 'd["shield"]["blocked_total"]')
  if [[ -n "$before" && -n "$after" && $after -gt $before ]]; then ok "Shield refuses trackers and counts them"; else bad "Shield count did not move ($before -> $after)"; fi
fi
curl -sS --max-time 15 --socks5-hostname "127.0.0.1:$STEALTH" -o /dev/null https://example.com/ && ok "Shield leaves ordinary sites alone" || bad "an ordinary site failed through Shield"

# 9. a pause from the device lets the tracker through, and resuming ends it
paused=$(field "$(ask "$STEALTH" shield-pause)" 'd["shield"]["paused_until"] > 0')
reach=$(curl -sS --max-time 15 --socks5-hostname "127.0.0.1:$STEALTH" -o /dev/null -w '%{http_code}' https://stats.g.doubleclick.net/ 2>/dev/null)
resumed=$(field "$(ask "$STEALTH" shield-resume)" 'd["shield"]["paused_until"] == 0')
if [[ $paused == True && $reach =~ ^[1-5][0-9][0-9]$ && $resumed == True ]]; then
  ok "pausing Shield works and resuming ends it"
else
  bad "Shield pause: paused=$paused reach=$reach resumed=$resumed"
fi

if [[ "${1:-}" != "--live" ]]; then
  # 10. a revoked key that tries again is reported to the owner
  for _ in $(seq 1 15); do
    grep -q '"device": "retired"' "$WORK/status.json" 2>/dev/null && break
    sleep 1
  done
  grep -q '"device": "retired"' "$WORK/status.json" && ok "a revoked key trying to connect raises an alert" || bad "no alert for the revoked key"

  # 11. an exit that serves only the stealth link stays silent to plain clients
  SPORT=$(free_port)
  sed -e "s#^c2e_listen: .*#c2e_listen: 127.0.0.1:$SPORT#" -e "s#^b2e_listen: .*#b2e_listen: 127.0.0.1:$(free_port)#" \
      -e "s#^kestrel_status: .*#kestrel_status: $WORK/status2.json#" "$WORK/exit.yaml" > "$WORK/stealth-exit.yaml"
  echo "kestrel_allow_plain: false" >> "$WORK/stealth-exit.yaml"
  "$BIN/geph5-exit" --config "$WORK/stealth-exit.yaml" > "$WORK/stealth-exit.log" 2>&1 &
  PIDS+=($!)
  sleep 2
  sed "s#direct: .*/#direct: 127.0.0.1:$SPORT/#" "$WORK/stealth.cfg" > "$WORK/stealth-only.cfg"
  sed "s#direct: .*/#direct: 127.0.0.1:$SPORT/#" "$WORK/plain.cfg" > "$WORK/plain-only.cfg"
  P=$(start_client stealthonly "$WORK/stealth-only.cfg")
  expect_works "stealth-only exit serves the stealth link" "$P"
  P=$(start_client plainonly "$WORK/plain-only.cfg")
  expect_refused "stealth-only exit refuses the plain link" "$P"
  echo=$(printf '\x00\x05hello' | timeout 8 nc -w 6 127.0.0.1 "$SPORT" 2>/dev/null | wc -c)
  [[ "$echo" == 0 ]] && ok "stealth-only exit does not answer a Geph ping" || bad "stealth-only exit echoed $echo bytes"
fi

echo "lockdown: $PASS passed, $FAIL failed"
[[ $FAIL == 0 ]]
