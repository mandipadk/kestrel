#!/usr/bin/env bash
# Finish a rebase that stops only on Cargo.lock conflicts, without guessing.
#
#   lock-merge.sh            (run in the repo while a rebase is stopped)
#
# For each stopped commit whose only conflicted file is Cargo.lock:
#   1. take upstream's side of Cargo.lock (the tree being rebased onto),
#   2. let cargo re-lock it for this commit's Cargo.toml files,
#   3. lift every crate our commit had locked newer, on the same compatible
#      line, back to our version (cargo update --precise), so security bumps
#      survive and nothing moves backwards,
#   4. continue the rebase.
# Exits 0 when the rebase is finished, 1 when it stops on anything else
# (another file conflicts, or cargo can't re-lock): the caller handles that.
set -uo pipefail
export PATH="$HOME/.cargo/bin:$PATH"
LIFT_PY=$(dirname "$(readlink -f "$0")")/lock-lift.py

for _ in $(seq 1 500); do
  git rev-parse -q --verify REBASE_HEAD >/dev/null || exit 0   # rebase finished
  conflicted=$(git diff --name-only --diff-filter=U)
  if [[ "$conflicted" != "Cargo.lock" ]]; then
    echo "lock-merge: conflicts beyond Cargo.lock: $(echo $conflicted)"
    exit 1
  fi
  commit=$(git rev-parse --short REBASE_HEAD)
  echo "lock-merge: $commit $(git log -1 --format=%s REBASE_HEAD | cut -c1-70)"
  ours=$(mktemp)
  git show REBASE_HEAD:Cargo.lock > "$ours"
  git checkout --ours -- Cargo.lock          # in a rebase, "ours" is upstream's side
  if ! cargo metadata --format-version 1 >/dev/null 2>"$ours.err"; then
    echo "lock-merge: cargo could not re-lock: $(tail -3 "$ours.err" | tr '\n' ' ')"
    rm -f "$ours" "$ours.err"; exit 1
  fi
  python3 "$LIFT_PY" "$ours" Cargo.lock | while read -r spec ver; do
    if cargo update -p "$spec" --precise "$ver" >/dev/null 2>"$ours.err"; then
      echo "  kept ours: $spec -> $ver"
    else
      echo "  could not lift $spec to $ver: $(tail -1 "$ours.err")"
    fi
  done
  rm -f "$ours" "$ours.err"
  git add Cargo.lock
  # a commit that only bumped Cargo.lock may now be empty: drop it
  if git diff --cached --quiet; then
    git rebase --skip >/dev/null 2>&1 || true
  else
    GIT_EDITOR=true git rebase --continue >/dev/null 2>&1 || true
  fi
done
echo "lock-merge: gave up after too many steps"
exit 1
