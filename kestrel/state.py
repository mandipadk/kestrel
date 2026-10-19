#!/usr/bin/env python3
"""Print Kestrel's state as one JSON object, for the status page."""
import json
import os
import subprocess
import time

STATE = "/var/lib/kestrel"


def load(path, default=None):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return default


def run(*args):
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=10).stdout
    except Exception:
        return ""


def unit(name, *props):
    out = run("systemctl", "show", name, "--property=" + ",".join(props))
    return dict(line.split("=", 1) for line in out.splitlines() if "=" in line)


def city():
    try:
        with open("/etc/kestrel/exit.yaml") as f:
            for line in f:
                if line.startswith("city:"):
                    return line.split(":", 1)[1].strip()
    except Exception:
        pass
    return None


def allowed():
    try:
        with open(f"{STATE}/shield-allow.txt") as f:
            return sorted({l.strip() for l in f if l.strip() and not l.startswith("#")})
    except Exception:
        return []


def list_info():
    try:
        st = os.stat(f"{STATE}/shield-list.txt")
        count = None
        with open(f"{STATE}/shield-list.txt") as f:
            for _, line in zip(range(30), f):  # oisd states its size up top
                if line.startswith("# Entries:"):
                    count = int(line.split(":", 1)[1])
        return {"domains": count, "updated": int(st.st_mtime)}
    except Exception:
        return None


def watch():
    """What this exit saw of the other one (watch.sh): last check, uptime over
    24 hours and 30 days, and a day-by-day strip (oldest first)."""
    rows = []
    try:
        with open(f"{STATE}/reports/watch.jsonl") as f:
            rows = [json.loads(l) for l in f if l.strip()]
    except Exception:
        return {}
    now = int(time.time())
    out = {}
    for target in sorted({r["target"] for r in rows}):
        mine = [r for r in rows if r["target"] == target]
        up = lambda r: bool(r.get("direct") or r.get("disguised"))
        share = lambda rs: round(sum(map(up, rs)) / len(rs), 4) if rs else None
        days = []
        for back in range(29, -1, -1):
            lo, hi = now - (back + 1) * 86400, now - back * 86400
            day = [r for r in mine if lo <= r["at"] < hi]
            days.append({"checks": len(day), "up": sum(map(up, day))})
        out[target] = {
            "last": mine[-1],
            "up24h": share([r for r in mine if r["at"] >= now - 86400]),
            "up30d": share(mine),
            "days": days,
        }
    return out


status = load(f"{STATE}/status.json", {}) or {}
# keys replaced by a rotation stay in the file (so their use can be spotted)
# but are not devices of their own
devices = [d for d in (load(f"{STATE}/devices.json", {}) or {}).get("devices", []) if not d.get("replaced")]
usage = status.get("devices", {})
out = {
    "city": city(),
    "exit": unit("geph-exit", "ActiveState", "SubState", "ActiveEnterTimestamp", "NRestarts", "UnitFileState"),
    "exitStarted": status.get("started"),
    "statusUpdated": status.get("updated"),
    "devices": [
        {**d, **usage.get(d["name"], {})}
        for d in devices
        if d["name"] != "lockdown-probe"
    ],
    "probe": usage.get("lockdown-probe", {}),
    "alerts": status.get("alerts", []),
    "rejected24h": status.get("rejected_24h", 0),
    "allowed": allowed(),
    "shieldList": list_info(),
    "timers": {
        t: unit(t, "ActiveState", "NextElapseUSecRealtime", "LastTriggerUSec")
        for t in ("geph-upstream-sync.timer", "geph-security-review.timer", "kestrel-follow.timer", "kestrel-devices.timer", "kestrel-watch.timer")
    },
    # the second exit: following Frankfurt's release
    "follow": load(f"{STATE}/reports/latest-follow.json"),
    "sync": load(f"{STATE}/reports/latest-sync.json"),
    "review": load(f"{STATE}/reports/latest-review.json"),
    "release": run("readlink", "/opt/kestrel/current").strip().rsplit("/", 1)[-1],
    "lastGood": run("readlink", "/opt/kestrel/last-good").strip().rsplit("/", 1)[-1],
    "pubkey": run("/opt/kestrel/current/kestrelctl", "pubkey").strip(),
    "watch": watch(),
    # each exit's disguised address host (the path stays private)
    "disguise": {e["city"]: e["disguise"].split("/")[2] for e in (load(f"{STATE}/exits.json", []) or []) if e.get("disguise")},
}
print(json.dumps(out))
