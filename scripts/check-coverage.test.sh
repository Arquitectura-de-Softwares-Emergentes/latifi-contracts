#!/usr/bin/env bash
# check-coverage.test.sh: self-test for check-coverage.sh with synthetic lcov files.
#
# Works on macOS bash 3.2 and Ubuntu bash 5.

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
GATE="$HERE/check-coverage.sh"

TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

TOTAL=0
PASSED=0

# record FILE SF FOUND HIT: append one lcov record. The DA, FNF and BRF lines are noise that the
# gate must ignore.
record() {
  {
    printf 'TN:\n'
    printf 'SF:%s\n' "$2"
    printf 'FNF:3\nFNH:3\n'
    printf 'DA:1,1\nDA:2,0\n'
    printf 'LF:%s\n' "$3"
    printf 'LH:%s\n' "$4"
    printf 'BRF:0\nBRH:0\n'
    printf 'end_of_record\n'
  } >> "$1"
}

# expect NAME EXPECTED_EXIT PATTERN GATE_ARGS...: PATTERN (fixed string, may be empty) must appear in
# the combined output.
expect() {
  name=$1
  want=$2
  pattern=$3
  shift 3
  TOTAL=$((TOTAL + 1))
  bash "$GATE" "$@" > "$TMP_ROOT/out.txt" 2>&1
  code=$?
  verdict=ok
  if [ "$code" -ne "$want" ]; then
    verdict="exit $code, expected $want"
  elif [ -n "$pattern" ] && ! grep -qF -- "$pattern" "$TMP_ROOT/out.txt"; then
    verdict="output lacks '$pattern'"
  fi
  if [ "$verdict" = ok ]; then
    PASSED=$((PASSED + 1))
    echo "PASS $TOTAL $name"
  else
    echo "FAIL $TOTAL $name ($verdict)"
    sed 's/^/    /' "$TMP_ROOT/out.txt"
  fi
}

F="$TMP_ROOT/full.info"
: > "$F"
record "$F" src/LoanBook.sol 40 40
record "$F" src/MockStablecoin.sol 17 17
expect "two files at 100 percent exit 0" 0 "ok" "$F" 90

F="$TMP_ROOT/low.info"
: > "$F"
record "$F" src/LoanBook.sol 40 40
record "$F" src/MockStablecoin.sol 100 89
expect "one file at 89 of 100 exits 1 and is named" 1 "src/MockStablecoin.sol" "$F" 90
expect "the failing line says BELOW" 1 "BELOW 90%" "$F" 90
expect "the passing file is still listed as ok" 1 "src/LoanBook.sol" "$F" 90

F="$TMP_ROOT/exact.info"
: > "$F"
record "$F" src/LoanBook.sol 100 90
expect "a file at exactly 90 of 100 exits 0" 0 "90.00%" "$F" 90

F="$TMP_ROOT/over.info"
: > "$F"
record "$F" src/LoanBook.sol 100 91
expect "the same report fails at 92" 1 "BELOW 92%" "$F" 92

F="$TMP_ROOT/none.info"
: > "$F"
record "$F" lib/forge-std/src/Test.sol 10 10
expect "no file under the prefix exits 2" 2 "no files under src/" "$F" 90

F="$TMP_ROOT/empty.info"
: > "$F"
expect "an empty report exits 2" 2 "no files under src/" "$F" 90

F="$TMP_ROOT/zero.info"
: > "$F"
record "$F" src/Empty.sol 0 0
expect "a file with zero found lines is accepted" 0 "100.00%" "$F" 90

expect "a missing lcov file exits 2" 2 "not found" "$TMP_ROOT/does-not-exist.info" 90

F="$TMP_ROOT/lib.info"
: > "$F"
record "$F" src/LoanBook.sol 40 40
record "$F" lib/forge-std/src/Test.sol 100 1
expect "a low coverage file under lib/ is ignored by the src/ prefix" 0 "" "$F" 90 src/

F="$TMP_ROOT/min101.info"
: > "$F"
record "$F" src/LoanBook.sol 40 40
expect "a minimum of 101 fails a fully covered file" 1 "BELOW 101%" "$F" 101
expect "a minimum of 100 accepts a fully covered file" 0 "" "$F" 100
expect "a minimum of 0 accepts anything" 0 "" "$F" 0

expect "a minimum of abc exits 2" 2 "integer" "$F" abc
expect "a minimum of 102 exits 2" 2 "integer" "$F" 102
expect "a negative minimum exits 2" 2 "integer" "$F" -5
expect "a decimal minimum exits 2" 2 "integer" "$F" 90.5
expect "an empty minimum exits 2" 2 "integer" "$F" ""
expect "a missing argument exits 2" 2 "usage" "$F"

F="$TMP_ROOT/broken.info"
printf 'SF:src/Broken.sol\nDA:1,1\nend_of_record\n' > "$F"
expect "a file without LF and LH records exits 2" 2 "no LF or LH" "$F" 90

F="$TMP_ROOT/prefix.info"
: > "$F"
record "$F" src/LoanBook.sol 40 40
record "$F" script/Deploy.s.sol 10 0
expect "a custom prefix checks only its own files" 1 "script/Deploy.s.sol" "$F" 90 script/
expect "the default prefix ignores script/" 0 "" "$F" 90

echo "PASS $PASSED/$TOTAL"
[ "$PASSED" -eq "$TOTAL" ]
