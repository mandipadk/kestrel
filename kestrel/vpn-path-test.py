#!/usr/bin/env python3
"""The apps' packet path, on Linux: does real web traffic get through?

  sudo vpn-path-test.py <libgeph5_client.so> <device config (yaml or json)> [--plain] [--keep]

The iPhone and Mac tunnels hand every packet to the engine with send_pkt and
write back whatever recv_pkt returns. This does exactly that, between the
engine and a TUN device in a private network namespace routed like the Mac's
tunnel (all IPv4 and IPv6, MTU 1450, DNS to 1.1.1.1), then loads real pages
and a download inside that namespace. Nothing outside the namespace is routed
through it. Exits non-zero if any check fails.
"""
import ctypes
import fcntl
import json
import os
import struct
import subprocess
import sys
import threading
import time

import yaml

NS = "kvpntest"
DEV = "kv0"
MTU = 1450
PAGES = ["https://example.com/", "https://www.wikipedia.org/", "https://www.google.com/", "https://github.com/", "https://www.apple.com/"]
DOWNLOAD = "https://speed.cloudflare.com/__down?bytes=25000000"

args = [a for a in sys.argv[1:] if not a.startswith("--")]
if len(args) != 2 or os.geteuid() != 0:
    sys.exit(__doc__)
lib_path, cfg_path = args
stealth = "--plain" not in sys.argv

failed = 0


def check(ok, what):
    global failed
    print(("ok    " if ok else "FAIL  ") + what, flush=True)
    failed |= not ok


def sh(*cmd, ns=False, **kw):
    full = (["ip", "netns", "exec", NS] if ns else []) + list(cmd)
    return subprocess.run(full, capture_output=True, text=True, **kw)


# the namespace and its TUN device, routed like the Mac tunnel
sh("ip", "netns", "del", NS)
subprocess.run(["ip", "netns", "add", NS], check=True)
os.makedirs(f"/etc/netns/{NS}", exist_ok=True)
with open(f"/etc/netns/{NS}/resolv.conf", "w") as f:
    f.write("nameserver 1.1.1.1\nnameserver 9.9.9.9\n")
home = os.open("/proc/self/ns/net", os.O_RDONLY)
target = os.open(f"/run/netns/{NS}", os.O_RDONLY)
os.setns(target, os.CLONE_NEWNET)
tun = os.open("/dev/net/tun", os.O_RDWR)
fcntl.ioctl(tun, 0x400454CA, struct.pack("16sH", DEV.encode(), 0x0001 | 0x1000))  # TUNSETIFF, IFF_TUN | IFF_NO_PI
os.setns(home, os.CLONE_NEWNET)
for cmd in (["ip", "link", "set", "lo", "up"],
            ["ip", "link", "set", DEV, "mtu", str(MTU), "up"],
            ["ip", "addr", "add", "100.89.0.2/32", "dev", DEV],
            ["ip", "route", "add", "default", "dev", DEV],
            ["ip", "-6", "addr", "add", "fd89::2/128", "dev", DEV, "nodad"],
            ["ip", "-6", "route", "add", "default", "dev", DEV]):
    r = sh(*cmd, ns=True)
    if r.returncode:
        sys.exit(f"{' '.join(cmd)}: {r.stderr.strip()}")

# the device's config, as the apps build it
with open(cfg_path) as f:
    cfg = yaml.safe_load(f)
cfg.update(allow_direct=False, broker=None, broker_keys=None, spoof_dns=False, passthrough_china=False, allow_lan=False)
cfg["cache"] = f"/tmp/{NS}-engine.db"
cfg["kestrel_device"]["stealth"] = stealth
cfg["kestrel_device"]["vpn_mtu"] = MTU  # as apps/shared/DeviceKey.swift sets it
for k in ("socks5_listen", "http_proxy_listen", "control_listen", "pac_listen"):
    cfg.pop(k, None)

geph = ctypes.CDLL(lib_path)
geph.start_client.argtypes = [ctypes.c_char_p, ctypes.c_int]
geph.send_pkt.argtypes = [ctypes.c_char_p, ctypes.c_int]
geph.recv_pkt.argtypes = [ctypes.c_char_p, ctypes.c_int]
rc = geph.start_client(json.dumps(cfg).encode(), -1)
check(rc == 0, f"engine started ({'stealth' if stealth else 'plain'} link)")

counts = {"up": 0, "down": 0, "down_max": 0, "down_over_mtu": 0}


def up():
    while True:
        pkt = os.read(tun, 65536)
        counts["up"] += 1
        geph.send_pkt(pkt, len(pkt))


def down():
    buf = ctypes.create_string_buffer(65536)
    while True:
        n = geph.recv_pkt(buf, len(buf))
        if n > 0:
            counts["down"] += 1
            counts["down_max"] = max(counts["down_max"], n)
            counts["down_over_mtu"] += n > MTU
            os.write(tun, buf.raw[:n])


threading.Thread(target=up, daemon=True).start()
threading.Thread(target=down, daemon=True).start()

# 1. a lookup, the way every page starts
t0 = time.time()
r = sh("getent", "ahostsv4", "example.com", ns=True, timeout=30)
check(r.returncode == 0, f"DNS through the tunnel ({time.time() - t0:.1f} s)")

# 2. real pages over HTTPS (TCP + TLS through the engine's stack)
for url in PAGES:
    r = sh("curl", "-sS", "-o", "/dev/null", "--max-time", "20", "-w", "%{http_code} %{time_total}", url, ns=True)
    code, _, secs = r.stdout.partition(" ")
    check(r.returncode == 0 and code[:1] in "23", f"{url} -> {r.stdout or r.stderr.strip()}")

# 3. the address sites see is the exit's
r = sh("curl", "-sS", "--max-time", "20", "https://api.ipify.org", ns=True)
print(f"      sites see {r.stdout.strip() or r.stderr.strip()}")

# 4. throughput
r = sh("curl", "-sS", "-o", "/dev/null", "--max-time", "60", "-w", "%{speed_download} %{size_download}", DOWNLOAD, ns=True)
speed, _, size = r.stdout.partition(" ")
mbps = float(speed or 0) * 8 / 1e6
check(r.returncode == 0 and int(float(size or 0)) == 25_000_000, f"25 MB download at {mbps:.0f} Mbit/s ({r.stderr.strip() or 'complete'})")

print(f"      packets up {counts['up']}, down {counts['down']} (largest {counts['down_max']} bytes)")
# Apple's packetFlow drops packets bigger than the tunnel's MTU; Linux takes them
check(counts["down_over_mtu"] == 0, f"no packet to the system is bigger than the {MTU}-byte MTU ({counts['down_over_mtu']} were)")
if "--keep" not in sys.argv:
    sh("ip", "netns", "del", NS)
    subprocess.run(["rm", "-rf", f"/etc/netns/{NS}", f"/tmp/{NS}-engine.db"])
sys.exit(1 if failed else 0)
