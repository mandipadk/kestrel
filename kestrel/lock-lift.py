#!/usr/bin/env python3
"""List crates our Cargo.lock had newer than the merged one, to lift back.

  lock-lift.py <our Cargo.lock> <merged Cargo.lock>

Prints "name@merged_version our_version" for each crate where the merged lock
has an older version on the same compatible line (same major, or same 0.minor)
than ours, and ours has no newer one already on that line. Nothing older is
ever printed, so applying the list never moves a crate backwards.
"""
import re
import sys

try:
    import tomllib
except ImportError:  # Python < 3.11
    tomllib = None


def packages(path):
    text = open(path, encoding="utf-8").read()
    if tomllib:
        return [(p["name"], p["version"]) for p in tomllib.loads(text).get("package", [])]
    return re.findall(r'\[\[package\]\]\nname = "([^"]+)"\nversion = "([^"]+)"', text)


def key(version):
    core, _, pre = version.partition("+")[0].partition("-")
    nums = tuple(int(x) for x in core.split("."))
    # a release sorts after its pre-releases
    return nums, (1,) if not pre else (0, pre)


def line(version):
    nums = key(version)[0]
    if nums[0] != 0:
        return (nums[0],)
    if nums[1] != 0:
        return (0, nums[1])
    return (0, 0, nums[2])


def main():
    ours, merged = packages(sys.argv[1]), packages(sys.argv[2])
    best = {}
    for name, ver in ours:
        k = (name, line(ver))
        if k not in best or key(ver) > key(best[k]):
            best[k] = ver
    for name, ver in merged:
        want = best.get((name, line(ver)))
        if want and key(want) > key(ver):
            print(f"{name}@{ver} {want}")


if __name__ == "__main__":
    main()
