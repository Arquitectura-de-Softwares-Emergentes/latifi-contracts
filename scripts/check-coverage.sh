#!/usr/bin/env bash
# check-coverage.sh: per-file line coverage gate over an lcov report.
#
# Usage: check-coverage.sh LCOV_FILE MIN_PERCENT [SF_PREFIX]
#   LCOV_FILE    report written by forge coverage --report lcov
#   MIN_PERCENT  integer from 0 to 101, every file must reach it (101 can never pass, which is how
#                the self-test and the CI proof show that the gate bites)
#   SF_PREFIX    only files whose path starts with this prefix are checked, default src/
#
# The threshold applies to each file, never to an average. Only the SF, LF and LH records are read.
# A file with zero found lines counts as 100 percent.
#
# Exit codes: 0 every file reaches the minimum, 1 at least one file is below it, 2 bad input (missing
# file, MIN_PERCENT not an integer from 0 to 101, a file without LF or LH records, or no file under
# the prefix). POSIX awk only. Works on macOS bash 3.2 and Ubuntu bash 5.

set -u

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo "usage: check-coverage.sh LCOV_FILE MIN_PERCENT [SF_PREFIX]" >&2
  exit 2
fi

FILE=$1
MIN=$2
PREFIX=${3:-src/}

if [ ! -f "$FILE" ]; then
  echo "coverage: report not found: $FILE" >&2
  exit 2
fi

case "$MIN" in
  '' | *[!0-9]*)
    echo "coverage: MIN_PERCENT must be an integer from 0 to 101, got '$MIN'" >&2
    exit 2
    ;;
esac
if [ "$MIN" -gt 101 ]; then
  echo "coverage: MIN_PERCENT must be an integer from 0 to 101, got '$MIN'" >&2
  exit 2
fi

awk -F: -v min="$MIN" -v prefix="$PREFIX" '
  $1 == "SF" {
    sf = substr($0, 4)
    if (!(sf in seen)) { seen[sf] = 1; order[++n] = sf }
    next
  }
  $1 == "LF" { lf[sf] = $2 + 0; haslf[sf] = 1; next }
  $1 == "LH" { lh[sf] = $2 + 0; haslh[sf] = 1; next }
  END {
    status = 0
    checked = 0
    for (i = 1; i <= n; i++) {
      f = order[i]
      if (index(f, prefix) != 1) continue
      checked++
      if (!haslf[f] || !haslh[f]) {
        print "coverage: " f " has no LF or LH record" > "/dev/stderr"
        bad = 1
        continue
      }
      pct = (lf[f] == 0) ? 100 : (lh[f] * 100) / lf[f]
      ok = (pct >= min)
      printf "%-40s %6.2f%% (%d/%d) %s\n", f, pct, lh[f], lf[f], ok ? "ok" : "BELOW " min "%"
      if (!ok) status = 1
    }
    if (checked == 0) {
      print "coverage: no files under " prefix " in the report" > "/dev/stderr"
      exit 2
    }
    if (bad) exit 2
    exit status
  }' "$FILE"
