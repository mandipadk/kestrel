#!/usr/bin/env bash
# Kestrel exit watch: every 5 minutes (kestrel-watch.timer) each exit checks
# the other one the way a device uses it: the lockdown probe's key, a full
# handshake pinned to that exit, and a page fetched through it. If the other
# exit has a disguised address, that path is checked too.
#
# Results go to /var/lib/kestrel/reports/watch.jsonl (30 days), which the
# status page shows as uptime. Ten minutes without an answer is reported to
# the agent on this work (notify.sh), once per outage, and so is the recovery.
#   watch.sh            check the other exit(s) once
set -uo pipefail
K=$(cd "$(dirname "$0")" && pwd)
STATE=/var/lib/kestrel
REPORTS=$STATE/reports
LOG=$REPORTS/watch.jsonl
DOWN=$REPORTS/watch-down.json
CLIENT=/opt/kestrel/current/geph5-client
KEEP_SECS=$((30 * 86400))
WORK=$(mktemp -d)
PIDS=()
cleanup() { for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; wait 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

exec 9>/tmp/kestrel-watch.lock
flock -n 9 || exit 0

HERE=$(grep -m1 '^city:' /etc/kestrel/exit.yaml | awk '{print $2}')
[[ -n $HERE ]] || { echo "can't tell which exit this is"; exit 1; }

free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }

# check <city> <direct|disguised> -> prints "ok <ms>" or "fail"
check() {
  local city=$1 link=$2 port cfg start out
  port=$(free_port)
  cfg=$WORK/$city-$link.yaml
  python3 - "$STATE/probe.yaml" "$STATE/exits.json" "$city" "$link" "$port" > "$cfg" <<'PY' || { echo fail; return; }
import json, sys, yaml
cfg = yaml.safe_load(open(sys.argv[1]))
exits = json.load(open(sys.argv[2]))
city, link, port = sys.argv[3], sys.argv[4], sys.argv[5]
target = next(e for e in exits if e["city"] == city)
if link == "disguised" and not target.get("disguise"):
    sys.exit(1)
dev = cfg["kestrel_device"]
dev["exits"] = [target]
dev["exit_choice"] = city
dev["stealth"] = True
dev["link"] = link
cfg["exit_constraint"] = {"direct": f'{target["endpoint"]}/{target["pubkey"]}'}
cfg["socks5_listen"] = f"127.0.0.1:{port}"
cfg.pop("http_proxy_listen", None)
cfg.pop("control_listen", None)
cfg.pop("vpn", None)
print(yaml.safe_dump(cfg))
PY
  "$CLIENT" --config "$cfg" > "$WORK/$city-$link.log" 2>&1 &
  PIDS+=($!)
  start=$(date +%s%3N)
  for _ in $(seq 1 15); do
    out=$(curl -s --max-time 6 --socks5-hostname "127.0.0.1:$port" https://1.1.1.1/cdn-cgi/trace 2>/dev/null) || true
    if grep -q '^ip=' <<<"$out"; then
      echo "ok $(( $(date +%s%3N) - start ))"
      return
    fi
    sleep 2
  done
  echo fail
}

NOW=$(date +%s)
mapfile -t OTHERS < <(python3 -c '
import json, sys
for e in json.load(open(sys.argv[1])):
    if e["city"] != sys.argv[2]:
        print(e["city"], "yes" if e.get("disguise") else "no")
' "$STATE/exits.json" "$HERE")

for line in "${OTHERS[@]}"; do
  read -r city has_disguise <<<"$line"
  read -r direct direct_ms <<<"$(check "$city" direct)"
  disguised=null disguised_ms=null
  if [[ $has_disguise == yes ]]; then
    read -r d d_ms <<<"$(check "$city" disguised)"
    if [[ $d == ok ]]; then disguised=true; disguised_ms=$d_ms; else disguised=false; fi
  fi
  [[ $direct == ok ]] && direct=true || { direct=false; direct_ms=null; }
  echo "{\"at\":$NOW,\"from\":\"$HERE\",\"target\":\"$city\",\"direct\":$direct,\"direct_ms\":${direct_ms:-null},\"disguised\":$disguised,\"disguised_ms\":$disguised_ms}" >> "$LOG"
  echo "$city: direct=$direct (${direct_ms:-} ms) disguised=$disguised (${disguised_ms} ms)"

  # down twice in a row (10 minutes): report once; and say when it's back
  python3 - "$LOG" "$DOWN" "$city" <<'PY'
import json, subprocess, sys, os
log, down_file, city = sys.argv[1:]
rows = [json.loads(l) for l in open(log) if l.strip()]
mine = [r for r in rows if r["target"] == city][-2:]
try:
    down = json.load(open(down_file))
except Exception:
    down = {}
failing = len(mine) == 2 and not any(r["direct"] or r["disguised"] for r in mine)
if failing and city not in down:
    down[city] = mine[0]["at"]
    msg = f"Kestrel exit watch: the {city} exit has not answered a device handshake for 10 minutes. Devices fail over to the other exit."
    print("REPORT", msg)
elif not failing and city in down and mine and (mine[-1]["direct"] or mine[-1]["disguised"]):
    mins = (mine[-1]["at"] - down.pop(city)) // 60
    msg = f"Kestrel exit watch: the {city} exit answers again (down about {mins} minutes)."
    print("REPORT", msg)
else:
    msg = None
json.dump(down, open(down_file, "w"))
PY
done > "$WORK/out.txt" 2>&1
cat "$WORK/out.txt"
grep '^REPORT ' "$WORK/out.txt" | sed 's/^REPORT //' | while read -r msg; do "$K/notify.sh" "$msg" || true; done

# keep 30 days
python3 - "$LOG" "$((NOW - KEEP_SECS))" <<'PY'
import json, os, sys
path, cutoff = sys.argv[1], int(sys.argv[2])
rows = [l for l in open(path) if l.strip() and json.loads(l)["at"] >= cutoff]
tmp = path + ".tmp"
open(tmp, "w").writelines(rows)
os.replace(tmp, path)
PY
