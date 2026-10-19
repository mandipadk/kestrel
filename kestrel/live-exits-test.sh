#!/usr/bin/env bash
# Kestrel two-exit test against the live exits (run on Frankfurt).
#
#   live-exits-test.sh
#
# Runs on either exit (the local one is reached over loopback).
# The probe device gets both live exits, each reached through a small local
# relay. Freezing a relay cuts that exit off for this device only (the live
# services are never touched), so we can prove: automatic mode connects, the
# exits tell the device about each other, a cut-off exit is left for the other,
# and a pin is honoured. Exits non-zero if any check fails.
set -uo pipefail

PASS=0
FAIL=0
ok()   { echo "  ok    $*"; PASS=$((PASS + 1)); }
bad()  { echo "  FAIL  $*"; FAIL=$((FAIL + 1)); }

BIN=/opt/kestrel/current
CLIENT=$BIN/geph5-client
PROBE=/var/lib/kestrel/probe.yaml
EXITS=/var/lib/kestrel/exits.json
WORK=$(mktemp -d /tmp/kestrel-live-exits.XXXXXX)
PIDS=()
cleanup() {
  # clients start inside $(...), so their pids are kept in a file, not in PIDS
  for p in "${PIDS[@]}" $(cat "$WORK/pids" 2>/dev/null); do kill -CONT "$p" 2>/dev/null; kill "$p" 2>/dev/null; done
  wait 2>/dev/null
  # a failed run keeps its client logs
  [[ -n ${KEEP:-} || $FAIL != 0 ]] && echo "kept $WORK" || rm -rf "$WORK"
}
trap cleanup EXIT

free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])'; }
through() { curl -sS --max-time "${3:-25}" --socks5-hostname "127.0.0.1:$1" "$2"; }
ask() { curl -sS --max-time 15 --socks5-hostname "127.0.0.1:$1" "telnet://$2.kestrel.internal:1" </dev/null 2>/dev/null; }
field() { python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(eval(sys.argv[2]))' "$1" "$2" 2>/dev/null; }
city() { field "$(ask "$1" status)" 'd["exit"]["city"]'; }

# relay <listen-port> <host:port>: a plain TCP forwarder we can freeze
relay() {
  python3 - "$1" "$2" > /dev/null 2>&1 <<'PY' &
import socket, sys, threading
lp = int(sys.argv[1]); host, port = sys.argv[2].rsplit(":", 1)
def pump(a, b):
    try:
        while (d := a.recv(65536)):
            b.sendall(d)
    except OSError:
        pass
    for s in (a, b):
        try: s.shutdown(socket.SHUT_RDWR)
        except OSError: pass
srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", lp)); srv.listen(64)
while True:
    c, _ = srv.accept()
    u = socket.create_connection((host, int(port)))
    for a, b in ((c, u), (u, c)):
        threading.Thread(target=pump, args=(a, b), daemon=True).start()
PY
  echo $!
}

# client <name> [pin]: the probe device with both exits behind their relays
client() {
  local port ctl
  port=$(free_port); ctl=$(free_port)
  python3 - "$PROBE" "$EXITS" "$port" "$ctl" "${RPORT[Chicago]}" "${RPORT[Frankfurt]}" "${2:-}" > "$WORK/$1.yaml" <<'PY'
import json, sys, yaml
cfg = yaml.safe_load(open(sys.argv[1]))
exits = json.load(open(sys.argv[2]))
relays = {"Chicago": sys.argv[5], "Frankfurt": sys.argv[6]}
for x in exits:
    x["endpoint"] = f"127.0.0.1:{relays[x['city']]}"
cfg["kestrel_device"]["exits"] = exits
cfg["kestrel_device"]["exit_choice"] = sys.argv[7] or None
cfg["socks5_listen"] = f"127.0.0.1:{sys.argv[3]}"
cfg["control_listen"] = f"127.0.0.1:{sys.argv[4]}"
cfg["http_proxy_listen"] = None
cfg["pac_listen"] = None
cfg["allow_lan"] = False
print(yaml.safe_dump(cfg))
PY
  "$CLIENT" --config "$WORK/$1.yaml" > "$WORK/$1.log" 2>&1 &
  echo $! >> "$WORK/pids"
  echo "$port"
}

# done_with_last: stop the newest client (one device opens up to ~7 connections a
# minute; several copies at once would run into the exits' 20/min-per-address limit)
done_with_last() { local p; p=$(tail -1 "$WORK/pids"); kill -CONT "$p" 2>/dev/null; kill "$p" 2>/dev/null; }

works() { # works <socks-port> -> prints the exit ip, fails if pages don't load
  local out
  for _ in 1 2 3 4; do
    out=$(through "$1" https://1.1.1.1/cdn-cgi/trace 2>/dev/null) && grep -q '^ip=' <<<"$out" && { grep '^ip=' <<<"$out"; return 0; }
    sleep 3
  done
  return 1
}

echo "Kestrel two-exit test (live exits)"
[[ -r $PROBE && -s $EXITS ]] || { bad "needs $PROBE and $EXITS"; echo "live-exits: $PASS passed, $FAIL failed"; exit 1; }
declare -A RPORT RPID IP=([Chicago]=64.181.219.94 [Frankfurt]=92.5.139.56)
HERE=$(python3 -c 'import yaml; print(yaml.safe_load(open("/etc/kestrel/exit.yaml"))["city"])' 2>/dev/null)
[[ -n $HERE ]] || HERE=$(grep -q '^city: Chicago' /etc/kestrel/exit.yaml 2>/dev/null && echo Chicago || echo Frankfurt)
for X in Chicago Frankfurt; do
  target="${IP[$X]}:443"; [[ $X == "$HERE" ]] && target=127.0.0.1:443
  RPORT[$X]=$(free_port); RPID[$X]=$(relay "${RPORT[$X]}" "$target"); PIDS+=(${RPID[$X]})
done
sleep 1

AUTO=$(client auto)
ip=$(works "$AUTO") && ok "automatic mode connects ($ip)" || bad "automatic mode does not connect"
FIRST=$(city "$AUTO")
[[ $FIRST == Chicago || $FIRST == Frankfurt ]] && ok "automatic mode picked $FIRST" || bad "no exit city in the report ($FIRST)"
[[ $(field "$(ask "$AUTO" status)" 'sorted(x["city"] for x in d["exits"])') == "['Chicago', 'Frankfurt']" ]] \
  && ok "the exit tells the device about both exits" || bad "the report does not list both exits"
[[ $(field "$(ask "$AUTO" status)" 'd["quantum_safe"]') == True ]] && ok "the session is quantum-safe" || bad "the session is not quantum-safe"

for X in Chicago Frankfurt; do
  P=$(client "pin-$X" "$X")
  ip=$(works "$P") && [[ $ip == "ip=${IP[$X]}" ]] && ok "pinned to $X, pages leave from $X ($ip)" || bad "pinned to $X, got '${ip:-nothing}'"
  [[ $(city "$P") == "$X" ]] && ok "the $X pin is honoured" || bad "the $X pin is not honoured"
  done_with_last
done

if [[ $FIRST == Chicago || $FIRST == Frankfurt ]]; then
  OTHER=$([[ $FIRST == Chicago ]] && echo Frankfurt || echo Chicago)
  kill -STOP "${RPID[$FIRST]}"; t0=$(date +%s); moved=""
  while (( $(date +%s) - t0 < 40 )); do
    [[ $(city "$AUTO") == "$OTHER" ]] && { moved=$(( $(date +%s) - t0 )); break; }
    sleep 1
  done
  [[ -n $moved ]] && ok "when $FIRST was cut off, the device moved to $OTHER in ${moved}s" || bad "the device did not move to $OTHER within 40s"
  ip=$(works "$AUTO") && [[ $ip == "ip=${IP[$OTHER]}" ]] && ok "pages load from $OTHER after the move ($ip)" || bad "pages after the move: '${ip:-nothing}'"
  PIN=$(client "pin-down" "$FIRST")
  if through "$PIN" https://1.1.1.1/cdn-cgi/trace 15 >/dev/null 2>&1; then bad "a device pinned to the cut-off $FIRST got through"
  else ok "a device pinned to the cut-off $FIRST does not use $OTHER"; fi
  done_with_last
  kill -CONT "${RPID[$FIRST]}"
  ip=$(works "$AUTO") && ok "still working once $FIRST is back ($ip)" || bad "not working once $FIRST is back"
fi

# A device set up when it knew only one exit (the apps' first connection) asks
# for its report through the engine's control method, as the apps do, learns
# the owner's exit list, and moves to the faster exit without reconnecting.
# Its known exit is reached through a relay that waits 1.5 s per connection,
# so the other exit, learnt from the report, is the faster one.
# LEARN_CLIENT: another engine build (a control run with an older one must fail).
SLOW=$(free_port)
python3 - "$SLOW" 127.0.0.1:443 > /dev/null 2>&1 <<'PY' &
import socket, sys, threading, time
lp = int(sys.argv[1]); host, port = sys.argv[2].rsplit(":", 1)
srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", lp)); srv.listen(64)
def pump(a, b):
    try:
        while (d := a.recv(65536)):
            b.sendall(d)
    except OSError:
        pass
    for s in (a, b):
        try: s.shutdown(socket.SHUT_RDWR)
        except OSError: pass
def handle(c):
    time.sleep(1.5)
    u = socket.create_connection((host, int(port)))
    threading.Thread(target=pump, args=(c, u), daemon=True).start()
    pump(u, c)
while True:
    c, _ = srv.accept()
    threading.Thread(target=handle, args=(c,), daemon=True).start()
PY
PIDS+=($!)
OTHER=$([[ $HERE == Chicago ]] && echo Frankfurt || echo Chicago)
LPORT=$(free_port); LCTL=$(free_port)
python3 - "$PROBE" "$EXITS" "$HERE" "$SLOW" "$LPORT" "$LCTL" > "$WORK/learn.yaml" <<'PY'
import json, sys, yaml
cfg = yaml.safe_load(open(sys.argv[1]))
here = dict(next(x for x in json.load(open(sys.argv[2])) if x["city"] == sys.argv[3]))
here["endpoint"] = f"127.0.0.1:{sys.argv[4]}"
cfg["kestrel_device"]["exits"] = [here]
cfg["kestrel_device"]["exit_choice"] = None
cfg["socks5_listen"] = f"127.0.0.1:{sys.argv[5]}"
cfg["control_listen"] = f"127.0.0.1:{sys.argv[6]}"
cfg["http_proxy_listen"] = None
cfg["pac_listen"] = None
cfg["allow_lan"] = False
print(yaml.safe_dump(cfg))
PY
"${LEARN_CLIENT:-$CLIENT}" --config "$WORK/learn.yaml" > "$WORK/learn.log" 2>&1 &
echo $! >> "$WORK/pids"
ip=$(works "$LPORT") && [[ $ip == "ip=${IP[$HERE]}" ]] && ok "a device that knows only $HERE uses it ($ip)" || bad "the one-exit device: '${ip:-nothing}'"
rpc() { python3 -c '
import json, socket, sys
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=20)
s.sendall((json.dumps({"jsonrpc": "2.0", "method": "kestrel_exit", "params": [sys.argv[2]], "id": 1}) + "\n").encode())
print(s.makefile().readline().strip())' "$1" "$2" 2>/dev/null; }
rpc "$LCTL" status > /dev/null
t0=$(date +%s); moved=""
while (( $(date +%s) - t0 < 30 )); do
  [[ $(city "$LPORT") == "$OTHER" ]] && { moved=$(( $(date +%s) - t0 )); break; }
  sleep 1
done
[[ -n $moved ]] && ok "after its report it learnt $OTHER and moved there in ${moved}s, no reconnect" || bad "it did not move to $OTHER after learning the exit list"
ip=$(works "$LPORT") && [[ $ip == "ip=${IP[$OTHER]}" ]] && ok "pages now leave from $OTHER ($ip)" || bad "pages after learning: '${ip:-nothing}'"

echo "live-exits: $PASS passed, $FAIL failed"
[[ $FAIL == 0 ]]
