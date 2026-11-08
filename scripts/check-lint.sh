#!/usr/bin/env bash
# check-lint.sh: repo rules that forge lint does not cover (Phase 3, success criterion 4).
#
# Usage: check-lint.sh [ROOT]
#   ROOT defaults to the git top level. The script works inside ROOT so the self-test can point it
#   at fixture trees.
#
# Exit codes: 0 clean (prints "lint: ok"), 1 at least one finding (each one goes to stderr as
# "lint: FILE: reason"), 2 when src/ has no Solidity file.
#
# Rules, all of them always run:
#   R1 every .sol under src/ has exactly one pragma solidity line and it is "pragma solidity 0.8.35;"
#   R2 no SafeMath and no unchecked anywhere in src/, comments included
#   R3 no require with a string argument in src/ (custom errors only)
#   R4 every state-changing external or public function of src/LoanBook.sol has nonReentrant
#   R5 nothing in script/ reads key material or broadcasts with an explicit key
#   R6 no admin surface in src/ outside MockStablecoin.sol: no access control, ownership, pause,
#      proxy, delegatecall, self destruct and no withdraw-like function in LoanBook
#
# The rules read text, not a syntax tree, so comments and NatSpec in src/ must avoid the banned
# words too. POSIX grep and awk only. Works on macOS bash 3.2 and Ubuntu bash 5.

set -u

ROOT=${1:-$(git rev-parse --show-toplevel)}
cd "$ROOT" || {
  echo "lint: cannot enter $ROOT" >&2
  exit 2
}

PIN='pragma solidity 0.8.35;'
FAIL=0

# fail FILE REASON
fail() {
  echo "lint: $1: $2" >&2
  FAIL=1
}

SRC_FILES=""
if [ -d src ]; then
  SRC_FILES=$(find src -name '*.sol' | sort)
fi
if [ -z "$SRC_FILES" ]; then
  echo "lint: src: no Solidity files found" >&2
  exit 2
fi

# R1: the only pragma solidity line is the exact pin.
for f in $SRC_FILES; do
  pragmas=$(grep -E '^[[:space:]]*pragma[[:space:]]+solidity' "$f" || true)
  if [ -z "$pragmas" ]; then
    fail "$f" "missing '$PIN'"
  elif [ "$pragmas" != "$PIN" ]; then
    fail "$f" "pragma must be exactly '$PIN' and appear once, found: $(printf '%s' "$pragmas" | tr '\n' '|')"
  fi
done

for f in $SRC_FILES; do
  # R2: banned constructs, comments included.
  if grep -qi 'safemath' "$f"; then
    fail "$f" "SafeMath is banned, Solidity 0.8 checks arithmetic itself"
  fi
  if grep -qw 'unchecked' "$f"; then
    fail "$f" "unchecked is banned in src/"
  fi
  # R3: join the lines first so a require split over several lines is still seen.
  if tr '\n' ' ' < "$f" | grep -qE 'require[[:space:]]*\([^;]*"'; then
    fail "$f" "require with a string message, use a custom error"
  fi
done

# R4: reentrancy guard presence on LoanBook. A header runs from the function keyword to the opening
# brace or the semicolon and may span several lines. Line comments are cut before the scan so a
# comment cannot supply the missing guard.
if [ -f src/LoanBook.sol ]; then
  scan=$(awk '
    function has(text, word) {
      return text ~ ("(^|[^A-Za-z0-9_])" word "([^A-Za-z0-9_]|$)")
    }
    {
      line = $0
      sub(/\/\/.*$/, "", line)
    }
    line ~ /^[[:space:]]*function[[:space:]]/ { collecting = 1; header = "" }
    collecting {
      header = header " " line
      if (line ~ /\{/ || line ~ /;[[:space:]]*$/) {
        collecting = 0
        count++
        if ((has(header, "external") || has(header, "public")) \
            && !has(header, "view") && !has(header, "pure") && !has(header, "nonReentrant")) {
          gsub(/[[:space:]]+/, " ", header)
          sub(/^ /, "", header)
          print "BAD " header
        }
      }
    }
    END { print "COUNT " count + 0 }
  ' src/LoanBook.sol)
  bad=$(printf '%s\n' "$scan" | grep '^BAD ' || true)
  count=$(printf '%s\n' "$scan" | sed -n 's/^COUNT //p')
  if [ -n "$bad" ]; then
    printf '%s\n' "$bad" | while IFS= read -r line; do
      echo "lint: src/LoanBook.sol: state-changing function without nonReentrant: ${line#BAD }" >&2
    done
    FAIL=1
  fi
  if [ "${count:-0}" -eq 0 ]; then
    fail "src/LoanBook.sol" "the nonReentrant scan found no function, the scan itself is broken"
  fi
fi

# R5: no key reads in script/.
if [ -d script ]; then
  for f in $(find script -name '*.sol' | sort); do
    if grep -qE 'envUint|envBytes32|PRIVATE_KEY|private-key|rememberKey|deriveKey' "$f"; then
      fail "$f" "reads key material"
    fi
    if tr '\n' ' ' < "$f" | grep -qE 'startBroadcast\([[:space:]]*[^[:space:])]'; then
      fail "$f" "startBroadcast with an argument, the signer must come from the CLI"
    fi
  done
fi

# R6: no admin surface. MockStablecoin is the only file allowed to use access control.
for f in $SRC_FILES; do
  [ "$(basename "$f")" = "MockStablecoin.sol" ] && continue
  if grep -qE 'AccessControl|Ownable|Pausable|Upgradeable|ERC1967|delegatecall|selfdestruct' "$f"; then
    fail "$f" "admin surface (access control, ownership, pause, proxy, delegatecall or self destruct)"
  fi
done
if [ -f src/LoanBook.sol ]; then
  if grep -qE 'function[[:space:]]+(pause|unpause|upgradeTo|transferOwnership|renounceOwnership|setOwner|withdraw|sweep|rescue)' src/LoanBook.sol; then
    fail "src/LoanBook.sol" "admin or custody function (pause, upgrade, ownership, withdraw, sweep or rescue)"
  fi
fi

if [ "$FAIL" -eq 0 ]; then
  echo "lint: ok"
fi
exit "$FAIL"
