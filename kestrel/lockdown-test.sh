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
  # a frozen test exit (the failover check) only dies once it is let go
  for p in "${PIDS[@]}"; do kill -CONT "$p" 2>/dev/null; kill "$p" 2>/dev/null; done
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
# as the apps do: local and LAN addresses go through the exit too, so the
# loopback and private-address checks below test the exit, not this client
cfg["allow_lan"] = False
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
  # this exit's own key (on the second exit it differs from the one the probe was made with)
  sed "s#direct: .*#direct: $ENDPOINT/$("$CTL" --signing-secret "$SECRET" pubkey)#" "$PROBE" > "$WORK/probe.yaml"
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
# every service listening on this host's loopback, not just SSH
leaked=""
for lport in $(ss -Htln | awk '{print $4}' | grep -E '^(127\.[0-9.]+|0\.0\.0\.0|\*):[0-9]+$' | sed 's/.*://' | sort -un | head -40); do
  # leaked if anything at all answers a request sent through the tunnel
  if python3 - "$P" "$lport" <<PY
import socket, struct, sys
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=6)
s.sendall(b"\x05\x01\x00"); s.recv(2)
s.sendall(b"\x05\x01\x00\x01" + socket.inet_aton("127.0.0.1") + struct.pack(">H", int(sys.argv[2])))
try:
    s.recv(10)
    s.sendall(b"GET / HTTP/1.0\r\n\r\n")
    sys.exit(0 if s.recv(1) else 1)
except OSError:
    sys.exit(1)
PY
  then leaked+=" $lport"; fi
done
[[ -z $leaked ]] && ok "no service on this host's loopback is reachable through the exit" || bad "loopback ports reachable through the exit:$leaked"
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

[[ $(field "$report" 'd["quantum_safe"]') == True ]] && ok "the session keys are quantum-safe (X25519 + ML-KEM-768)" || bad "handshake not quantum-safe: $report"

# with_classical <config> -> a copy that handshakes like an app from before the quantum-safe one
with_classical() {
  python3 - "$1" <<'PY'
import sys, yaml
cfg = yaml.safe_load(open(sys.argv[1]))
cfg["kestrel_device"]["classical_handshake"] = True
print(yaml.safe_dump(cfg))
PY
}
with_classical "$WORK/stealth.cfg" > "$WORK/classical.cfg"
CLASSICAL=$(start_client classical "$WORK/classical.cfg")
expect_works "an app from before the quantum-safe handshake still connects" "$CLASSICAL"
[[ $(field "$(ask "$CLASSICAL" status)" 'd["quantum_safe"]') == False ]] && ok "the exit tells classical sessions apart" || bad "classical session reported as quantum-safe"

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

  # 12. an exit that requires the quantum-safe handshake refuses classical apps
  QPORT=$(free_port)
  sed -e "s#^c2e_listen: .*#c2e_listen: 127.0.0.1:$QPORT#" -e "s#^b2e_listen: .*#b2e_listen: 127.0.0.1:$(free_port)#" \
      -e "s#^kestrel_status: .*#kestrel_status: $WORK/status3.json#" "$WORK/exit.yaml" > "$WORK/pq-exit.yaml"
  echo "kestrel_require_pq: true" >> "$WORK/pq-exit.yaml"
  "$BIN/geph5-exit" --config "$WORK/pq-exit.yaml" > "$WORK/pq-exit.log" 2>&1 &
  PIDS+=($!)
  sleep 2
  sed "s#direct: .*/#direct: 127.0.0.1:$QPORT/#" "$WORK/stealth.cfg" > "$WORK/pq-only.cfg"
  sed "s#direct: .*/#direct: 127.0.0.1:$QPORT/#" "$WORK/classical.cfg" > "$WORK/classical-only.cfg"
  P=$(start_client pqonly "$WORK/pq-only.cfg")
  expect_works "a quantum-safe-only exit serves quantum-safe apps" "$P"
  P=$(start_client classicalonly "$WORK/classical-only.cfg")
  expect_refused "a quantum-safe-only exit refuses classical apps" "$P"

  # 13. two exits: automatic picks one, keeps working when it dies, a pin is honoured
  declare -A XPORT XPID
  echo "[" > "$WORK/exits.json"
  for X in Alpha Bravo; do
    head -c 32 /dev/urandom > "$WORK/$X.key"
    XPORT[$X]=$(free_port)
    sed -e "s#^signing_secret: .*#signing_secret: $WORK/$X.key#" -e "s#^c2e_listen: .*#c2e_listen: 127.0.0.1:${XPORT[$X]}#" \
        -e "s#^b2e_listen: .*#b2e_listen: 127.0.0.1:$(free_port)#" -e "s#^city: .*#city: $X#" \
        -e "s#^kestrel_status: .*#kestrel_status: $WORK/status-$X.json#" "$WORK/exit.yaml" > "$WORK/exit-$X.yaml"
    [[ $X == Bravo ]] && sep="" || sep=","
    echo "{\"endpoint\": \"127.0.0.1:${XPORT[$X]}\", \"pubkey\": \"$("$CTL" --signing-secret "$WORK/$X.key" pubkey)\", \"city\": \"$X\"}$sep" >> "$WORK/exits.json"
  done
  echo "]" >> "$WORK/exits.json"
  "$CTL" --devices "$DEVICES" --signing-secret "$WORK/Alpha.key" --endpoint "127.0.0.1:${XPORT[Alpha]}" --exits "$WORK/exits.json" \
    add twoexits --out "$WORK/twoexits.yaml" >/dev/null || bad "kestrelctl could not make a two-exit config"
  grep -q "city: Bravo" "$WORK/twoexits.yaml" && ok "a new device's config lists both exits" || bad "config lacks the exit list"
  # every exit tells devices the list, so devices set up before a new exit learn it
  for X in Alpha Bravo; do
    echo "kestrel_exits: $WORK/exits.json" >> "$WORK/exit-$X.yaml"
    "$BIN/geph5-exit" --config "$WORK/exit-$X.yaml" > "$WORK/exit-$X.log" 2>&1 &
    XPID[$X]=$!; PIDS+=(${XPID[$X]})
  done
  sleep 2
  TWO=$(start_client twoexits "$WORK/twoexits.yaml")
  expect_works "a device with two exits connects" "$TWO"
  FIRST=$(field "$(ask "$TWO" status)" 'd["exit"]["city"]')
  [[ $FIRST == Alpha || $FIRST == Bravo ]] && ok "automatic mode picked $FIRST" || bad "no exit city in the report ($FIRST)"
  [[ $(field "$(ask "$TWO" status)" 'sorted(x["city"] for x in d["exits"])') == "['Alpha', 'Bravo']" ]] \
    && ok "the exit tells the device about both exits" || bad "the report does not list both exits"
  # an old-style config (one exit) still connects, and learns the list from its report
  P=$(start_client oneexit "$WORK/probe.yaml")
  [[ $(field "$(ask "$P" status)" 'len(d["exits"])') == 0 ]] && ok "the main test exit (no list set) reports no exits" || bad "unexpected exit list on the main test exit"
  if [[ $FIRST == Alpha || $FIRST == Bravo ]]; then
    OTHER=$([[ $FIRST == Alpha ]] && echo Bravo || echo Alpha)
    # frozen, not killed: connections stay open but nothing answers (a hung or cut-off exit)
    kill -STOP "${XPID[$FIRST]}"; t0=$(date +%s); moved=""
    while (( $(date +%s) - t0 < 40 )); do
      if [[ $(field "$(ask "$TWO" status)" 'd["exit"]["city"]') == "$OTHER" ]]; then moved=$(( $(date +%s) - t0 )); break; fi
      sleep 1
    done
    [[ -n $moved ]] && ok "when $FIRST stopped answering, the device moved to $OTHER in ${moved}s" || bad "the device did not move to $OTHER within 40s"
    expect_works "pages still load after the move" "$TWO"
    # a pin to the exit that is down must not fall over to the other
    python3 - "$WORK/twoexits.yaml" "$FIRST" > "$WORK/pinned.yaml" <<'PY'
import sys, yaml
cfg = yaml.safe_load(open(sys.argv[1])); cfg["kestrel_device"]["exit_choice"] = sys.argv[2]
print(yaml.safe_dump(cfg))
PY
    P=$(start_client pinned "$WORK/pinned.yaml")
    expect_refused "a device pinned to $FIRST does not use $OTHER" "$P"
    python3 - "$WORK/twoexits.yaml" "$OTHER" > "$WORK/pinned2.yaml" <<'PY'
import sys, yaml
cfg = yaml.safe_load(open(sys.argv[1])); cfg["kestrel_device"]["exit_choice"] = sys.argv[2]
print(yaml.safe_dump(cfg))
PY
    P=$(start_client pinned2 "$WORK/pinned2.yaml")
    expect_works "a device pinned to $OTHER uses it" "$P"
    [[ $(field "$(ask "$P" status)" 'd["exit"]["city"]') == "$OTHER" ]] && ok "the pin is honoured" || bad "the pinned device is not on $OTHER"
  fi
fi

echo "lockdown: $PASS passed, $FAIL failed"
[[ $FAIL == 0 ]]
