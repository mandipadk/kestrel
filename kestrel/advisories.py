#!/usr/bin/env python3
"""Sort the security review's advisories into new and accepted.

  advisories.py <cargo-audit.json> <osv.json or -> <advisories-accepted.txt>

Prints every advisory with its verdict, then a last line "new=N accepted=M".
An advisory is accepted when its id (or one of its aliases) is listed for the
same crate and version line in the accepted file. Exits 0 either way.
"""
import json
import sys


def load_accepted(path):
    accepted = []
    for line in open(path):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        ident, crate, prefix, reason = line.split(" ", 3)
        accepted.append((ident, crate, prefix, reason))
    return accepted


def version_line(version, prefix):
    return version == prefix or version.startswith(prefix + ".")


def main():
    audit_path, osv_path, accepted_path = sys.argv[1:4]
    accepted = load_accepted(accepted_path)
    found = {}  # (crate, version, primary id) -> (ids, title)
    try:
        audit = json.load(open(audit_path))
        for v in audit.get("vulnerabilities", {}).get("list", []):
            a, p = v["advisory"], v["package"]
            ids = {a["id"], *a.get("aliases", [])}
            found[(p["name"], p["version"], a["id"])] = (ids, a["title"])
    except (OSError, ValueError):
        print("cargo audit results unreadable")
    if osv_path != "-":
        try:
            osv = json.load(open(osv_path))
            for r in osv.get("results", []):
                for p in r.get("packages", []):
                    pk = p["package"]
                    for v in p.get("vulnerabilities", []):
                        ids = {v["id"], *v.get("aliases", [])}
                        # the same advisory under another id is already listed
                        if any(k[0] == pk["name"] and k[1] == pk["version"] and ids & found[k][0] for k in found):
                            continue
                        found[(pk["name"], pk["version"], v["id"])] = (ids, v.get("summary") or "")
        except (OSError, ValueError):
            print("OSV results unreadable")
    new = 0
    for (crate, version, ident), (ids, title) in sorted(found.items()):
        why = next((r for i, c, pre, r in accepted if c == crate and i in ids and version_line(version, pre)), None)
        if why is None:
            new += 1
            print(f"  NEW       {ident} {crate} {version}: {title[:80]}")
        else:
            print(f"  accepted  {ident} {crate} {version}: {why[:80]}")
    print(f"new={new} accepted={len(found) - new}")


main()
