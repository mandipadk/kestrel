#!/usr/bin/env bash
# How many new connections does one device open to each exit? (run on Frankfurt)
#
#   conn-rate-test.sh [seconds-per-phase]
#
# The exits' firewalls drop new connections from one address above 20/min
# (burst 40). One device, with both live exits behind counting relays, through
# three phases: connected, one exit cut off, the exit back. Prints the new
# connections each exit got per phase and the busiest minute, and fails if a
# single device would come near the firewall's limit.
set -uo pipefail
PHASE=${1:-90}
BIN=/opt/kestrel/current
PROBE=/var/lib/kestrel/probe.yaml
EXITS=/var/lib/kestrel/exits.json
WORK=$(mktemp -d /tmp/kestrel-connrate.XXXXXX)
PIDS=()
cleanup() {
  for p in "${PIDS[@]}"; do kill -CONT "$p" 2>/dev/null; kill "$p" 2>/dev/null; done
  wait 2>/dev/null; rm -rf "$WORK"
}
trap cleanup EXIT
free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])'; }

# relay <listen-port> <host:port> <log>: forwards, and logs the time of each new connection
relay() {
  python3 - "$1" "$2" "$3" > /dev/null 2>&1 <<'PY' &
import socket, sys, threading, time
lp = int(sys.argv[1]); host, port = sys.argv[2].rsplit(":", 1); log = open(sys.argv[3], "a", buffering=1)
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
    log.write(f"{time.time()}\n")
    u = socket.create_connection((host, int(port)))
    for a, b in ((c, u), (u, c)):
        threading.Thread(target=pump, args=(a, b), daemon=True).start()
PY
  echo $!
}

declare -A RP RPID
RP[Chicago]=$(free_port); RPID[Chicago]=$(relay "${RP[Chicago]}" 64.181.219.94:443 "$WORK/Chicago.conns"); PIDS+=(${RPID[Chicago]})
RP[Frankfurt]=$(free_port); RPID[Frankfurt]=$(relay "${RP[Frankfurt]}" 127.0.0.1:443 "$WORK/Frankfurt.conns"); PIDS+=(${RPID[Frankfurt]})
SOCKS=$(free_port); CTL=$(free_port)
python3 - "$PROBE" "$EXITS" "$SOCKS" "$CTL" "${RP[Chicago]}" "${RP[Frankfurt]}" > "$WORK/dev.yaml" <<'PY'
import json, sys, yaml
cfg = yaml.safe_load(open(sys.argv[1])); exits = json.load(open(sys.argv[2]))
relays = {"Chicago": sys.argv[5], "Frankfurt": sys.argv[6]}
for x in exits: x["endpoint"] = f"127.0.0.1:{relays[x['city']]}"
cfg["kestrel_device"]["exits"] = exits; cfg["kestrel_device"]["exit_choice"] = None
cfg.update(socks5_listen=f"127.0.0.1:{sys.argv[3]}", control_listen=f"127.0.0.1:{sys.argv[4]}",
           http_proxy_listen=None, pac_listen=None, allow_lan=False)
print(yaml.safe_dump(cfg))
PY
"$BIN/geph5-client" --config "$WORK/dev.yaml" > "$WORK/dev.log" 2>&1 &
PIDS+=($!)
city() { curl -sS --max-time 10 --socks5-hostname "127.0.0.1:$SOCKS" telnet://status.kestrel.internal:1 </dev/null 2>/dev/null \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["exit"]["city"])' 2>/dev/null; }
browse() { # light, steady use during a phase
  local end=$(( $(date +%s) + PHASE ))
  while (( $(date +%s) < end )); do curl -s -o /dev/null --max-time 10 --socks5-hostname "127.0.0.1:$SOCKS" https://1.1.1.1/cdn-cgi/trace; sleep 5; done
}
mark() { date +%s.%N > "$WORK/mark.$1"; }

mark 0; browse; ON=$(city)
mark 1; kill -STOP "${RPID[$ON]}"; browse
mark 2; kill -CONT "${RPID[$ON]}"; browse
mark 3
python3 - "$WORK" "$ON" <<'PY'
import sys, os
w, on = sys.argv[1], sys.argv[2]
m = [float(open(f"{w}/mark.{i}").read()) for i in range(4)]
names = ["connected", f"{on} cut off", f"{on} back"]
worst = 0
for city in ("Chicago", "Frankfurt"):
    p = f"{w}/{city}.conns"
    ts = [float(x) for x in open(p)] if os.path.exists(p) else []
    per = [sum(m[i] <= t < m[i+1] for t in ts) for i in range(3)]
    busiest = max((sum(t0 <= t < t0 + 60 for t in ts) for t0 in ts), default=0)
    worst = max(worst, busiest)
    print(f"{city:9} new connections: " + ", ".join(f"{n} {c}" for n, c in zip(names, per)) + f"; busiest minute {busiest}")
print(f"device was on {on}; firewall drops above 20/min after a burst of 40")
sys.exit(0 if worst <= 20 else 1)
PY
