#!/usr/bin/env bash
# Test lock-merge.sh on a throwaway clone: rebase the kestrel branch on
# upstream, let lock-merge finish it, and check no crate moved backwards
# compared with either side. The real repo is not touched.
#   lock-merge-test.sh [ref]   (default: kestrel)
set -euo pipefail
export PATH="$HOME/.cargo/bin:$PATH"
REPO=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap "rm -rf $T" EXIT
git clone -q "$REPO" "$T/r" && cd "$T/r"
git remote add upstream "$(git -C "$REPO" remote get-url upstream)"
git fetch -q upstream
git checkout -q -b t "origin/${1:-kestrel}"
cp "$REPO"/kestrel/lock-merge.sh "$REPO"/kestrel/lock-lift.py kestrel/
git show HEAD:Cargo.lock > "$T/ours.lock"; git show upstream/master:Cargo.lock > "$T/up.lock"
git rebase -q upstream/master >/dev/null 2>&1 || kestrel/lock-merge.sh
! git rev-parse -q --verify REBASE_HEAD >/dev/null || { echo "FAIL: rebase still stopped"; exit 1; }
git merge-base --is-ancestor upstream/master HEAD || { echo "FAIL: not on upstream"; exit 1; }
down=$(python3 kestrel/lock-lift.py "$T/ours.lock" Cargo.lock; python3 kestrel/lock-lift.py "$T/up.lock" Cargo.lock)
[[ -z "$down" ]] || { echo "FAIL: moved backwards:"; echo "$down"; exit 1; }
cargo metadata --locked --format-version 1 >/dev/null || { echo "FAIL: Cargo.lock out of date"; exit 1; }
echo "PASS: on upstream $(git rev-parse --short upstream/master), $(git rev-list --count upstream/master..HEAD) of our commits, nothing moved backwards"
