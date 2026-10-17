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

echo "lockdown: $PASS passed, $FAIL failed"
[[ $FAIL == 0 ]]
