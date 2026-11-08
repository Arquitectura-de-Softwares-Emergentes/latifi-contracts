#!/usr/bin/env bash
# Pin guard for the git submodules under lib/.
# forge install records the right revision in foundry.lock but can leave a different commit staged
# in the git index, so a fresh checkout would build other code than the one that was tested. This
# script compares the gitlink of every lock entry with the revision in the lock file.
# Run from anywhere inside the repo. Needs git and jq. LOCK_FILE overrides the lock path, which lets
# a self-check point at a mutated copy. Compatible with bash 3.2.
set -eu

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

LOCK="${LOCK_FILE:-foundry.lock}"

if [ ! -f "$LOCK" ]; then
  echo "deps: missing $LOCK" >&2
  exit 1
fi

STATUS=0
LIBS="$(jq -r 'keys[]' "$LOCK")"

if [ -z "$LIBS" ]; then
  echo "deps: $LOCK lists no libraries" >&2
  exit 1
fi

for lib in $LIBS; do
  want="$(jq -r --arg l "$lib" '.[$l].tag.rev // .[$l].rev // empty' "$LOCK")"
  have="$(git ls-files -s -- "$lib" | awk '$1 == "160000" {print $2}')"
  if [ -z "$want" ] || [ "$want" != "$have" ]; then
    echo "deps: $lib index=$have lock=$want" >&2
    STATUS=1
  fi
done

if [ "$STATUS" -ne 0 ]; then
  exit 1
fi

echo "deps: ok"
