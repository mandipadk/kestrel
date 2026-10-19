#!/usr/bin/env python3
"""Keep Shield's allow lists the same on both exits.

  allow-sync.py <state dir> <base file>

Run on the second exit by pull-devices.sh. Devices can allow a domain from
their app on whichever exit they are using (for themselves, or for every
device), and the page allows through Frankfurt, so both sides change. This
merges both ways against the last merged copy (the base): what one side added
since is added, what one side removed since is removed. The result is written
to whichever side differs, Frankfurt over SSH. The exits reload the files when
they change.

  shield-allow.txt            domains allowed for every device, one per line
  shield-allow-devices.json   {device: [domains]} each device allowed for itself
"""
import json
import os
import re
import subprocess
import sys

DOMAIN = re.compile(r"^(?=.{1,253}$)([a-z0-9-]{1,63}\.)+[a-z0-9-]{1,63}$")
GLOBAL = "shield-allow.txt"
DEVICES = "shield-allow-devices.json"
REMOTE_DIR = "/var/lib/kestrel"


def parse_global(text):
    return {l.strip() for l in text.splitlines() if DOMAIN.match(l.strip())}


def parse_devices(text):
    try:
        raw = json.loads(text or "{}")
    except ValueError:
        raw = {}
    return {k: {d for d in v if isinstance(d, str) and DOMAIN.match(d)} for k, v in raw.items() if isinstance(v, list)}


def show_global(s):
    return "".join(f"{d}\n" for d in sorted(s))


def show_devices(m):
    return json.dumps({k: sorted(v) for k, v in sorted(m.items()) if v}, indent=2)


def merge(base, local, remote):
    """Three-way merge of sets."""
    return (remote | (local - base)) - (base - local)


def ssh(cmd, stdin=None):
    return subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "frankfurt", cmd],
                          input=stdin, capture_output=True, text=True, check=True, timeout=30).stdout


def read(path):
    try:
        with open(path) as f:
            return f.read()
    except FileNotFoundError:
        return ""


def write_local(path, text):
    tmp = path + ".sync"
    with open(tmp, "w") as f:
        f.write(text)
    os.chmod(tmp, 0o660)
    os.replace(tmp, path)


def write_remote(name, text):
    ssh(f"umask 007; cat > {REMOTE_DIR}/.{name}.sync && mv -f {REMOTE_DIR}/.{name}.sync {REMOTE_DIR}/{name}", stdin=text)


def main():
    state, base_path = sys.argv[1:3]
    local_g = parse_global(read(f"{state}/{GLOBAL}"))
    local_d = parse_devices(read(f"{state}/{DEVICES}"))
    remote_g = parse_global(ssh(f"cat {REMOTE_DIR}/{GLOBAL} 2>/dev/null || true"))
    remote_d = parse_devices(ssh(f"cat {REMOTE_DIR}/{DEVICES} 2>/dev/null || true"))
    try:
        base = json.load(open(base_path))
        base_g = set(base["all"])
        base_d = {k: set(v) for k, v in base["devices"].items()}
    except (OSError, ValueError, KeyError):
        # first run: only what both sides agree on counts as already merged
        base_g = local_g & remote_g
        base_d = {k: local_d.get(k, set()) & remote_d.get(k, set()) for k in set(local_d) | set(remote_d)}

    merged_g = merge(base_g, local_g, remote_g)
    names = set(base_d) | set(local_d) | set(remote_d)
    merged_d = {k: merge(base_d.get(k, set()), local_d.get(k, set()), remote_d.get(k, set())) for k in names}
    merged_d = {k: v for k, v in merged_d.items() if v}

    changed = []
    if merged_g != remote_g:
        write_remote(GLOBAL, show_global(merged_g))
        changed.append("Frankfurt's list for every device")
    if merged_g != local_g:
        write_local(f"{state}/{GLOBAL}", show_global(merged_g))
        changed.append("this exit's list for every device")
    if merged_d != {k: v for k, v in remote_d.items() if v}:
        write_remote(DEVICES, show_devices(merged_d))
        changed.append("Frankfurt's device lists")
    if merged_d != {k: v for k, v in local_d.items() if v}:
        write_local(f"{state}/{DEVICES}", show_devices(merged_d))
        changed.append("this exit's device lists")
    tmp = base_path + ".tmp"
    with open(tmp, "w") as f:
        json.dump({"all": sorted(merged_g), "devices": {k: sorted(v) for k, v in merged_d.items()}}, f)
    os.replace(tmp, base_path)
    if changed:
        print("allow lists merged:", ", ".join(changed))


if __name__ == "__main__":
    if len(sys.argv) == 2 and sys.argv[1] == "--self-test":
        # what one side added stays; what one side removed goes; untouched stays
        b, l, r = {"a", "b", "c"}, {"a", "b", "x"}, {"a", "c", "y"}
        assert merge(b, l, r) == {"a", "x", "y"}, merge(b, l, r)
        assert merge(set(), {"x"}, {"y"}) == {"x", "y"}
        assert merge({"x"}, set(), {"x"}) == set()
        assert parse_global("ok.example\nbad domain\n# c\nUPPER.example\n") == {"ok.example"}
        assert parse_devices('{"iphone": ["a.example", "../x"], "x": 3}') == {"iphone": {"a.example"}}
        print("allow-sync self-test: ok")
    else:
        main()
