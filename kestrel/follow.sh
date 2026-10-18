#!/usr/bin/env bash
# Kestrel, on the second exit (Chicago): run the release Frankfurt runs.
# Frankfurt builds, tests and deploys (sync.sh); this copies its current
# release (both servers are arm64), proves this exit with the live lockdown
# test (pages through it, strangers refused, nothing on this host's loopback
# reachable), and rolls back to the last good release if it fails. The engine
# itself is the same build Frankfurt already tested on the packet path. Run by
# kestrel-follow.timer an hour after Frankfurt's daily sync.
#   follow.sh            follow Frankfurt if it moved
#   follow.sh --force    reinstall and retest even if unchanged
set -uo pipefail
K=$(cd "$(dirname "$0")" && pwd)
OPT=/opt/kestrel
REPORTS=/var/lib/kestrel/reports
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p "$REPORTS"
exec > >(tee "$REPORTS/follow-$STAMP.log") 2>&1

report() { # report <ok|failed> <summary>
  python3 - "$REPORTS/latest-follow.json" "$1" "$2" "$STAMP" <<'PY'
import json, sys
json.dump({"status": sys.argv[2], "summary": sys.argv[3], "at": sys.argv[4]}, open(sys.argv[1], "w"), indent=2)
PY
}
fail() {
  echo "FAILED: $1"; report failed "$1"
  "$K/notify.sh" "Kestrel Chicago: $1. It keeps running the last good build." || true
  exit 1
}

SHA=$(ssh -o BatchMode=yes -o ConnectTimeout=8 frankfurt 'basename "$(readlink -f /opt/kestrel/current)"') || fail "could not reach Frankfurt"
[[ $SHA =~ ^[0-9a-f]{12}$ ]] || fail "Frankfurt reported an odd release name: $SHA"
CUR=$(basename "$(readlink -f $OPT/current)" 2>/dev/null || true)
if [[ $SHA == "$CUR" && ${1:-} != --force ]]; then
  echo "already on $SHA"; report ok "On $SHA, same as Frankfurt."; exit 0
fi

echo "== fetch release $SHA"
REL=$OPT/releases/$SHA
mkdir -p "$REL.new"
for b in geph5-exit geph5-client kestrelctl; do
  scp -q -o BatchMode=yes "frankfurt:/opt/kestrel/releases/$SHA/$b" "$REL.new/$b" \
    || { rm -rf "$REL.new"; fail "could not copy $b of $SHA"; }
done
chmod 0755 "$REL.new"/*
rm -rf "$REL"; mv "$REL.new" "$REL"
# the scripts this release was tested with
git -C "$K/.." fetch -q origin && git -C "$K/.." checkout -q "$(ssh -o BatchMode=yes frankfurt "git -C ~/code/kestrel rev-parse HEAD")" 2>/dev/null \
  || echo "note: could not move the scripts to Frankfurt's commit"

echo "== install and restart"
PREV=$(readlink $OPT/current || true)
ln -sfn "releases/$SHA" $OPT/current.new && mv -T $OPT/current.new $OPT/current
sudo -n /usr/bin/systemctl restart geph-exit
sleep 4

echo "== live tests"
ok=0
systemctl is-active --quiet geph-exit && "$K/lockdown-test.sh" --live && ok=1
if [[ $ok == 1 ]]; then
  ln -sfn "releases/$SHA" $OPT/last-good
  ls -1t $OPT/releases | tail -n +6 | while read -r old; do
    [[ "releases/$old" != "$(readlink $OPT/last-good)" ]] && rm -rf "${OPT:?}/releases/$old"
  done
  report ok "Following Frankfurt: deployed $SHA. Lockdown passed."
  echo "deployed $SHA"
else
  if [[ -n $PREV ]]; then ln -sfn "$PREV" $OPT/current.new && mv -T $OPT/current.new $OPT/current; sudo -n /usr/bin/systemctl restart geph-exit; fi
  fail "release $SHA failed its live tests here; rolled back to ${PREV#releases/}"
fi
