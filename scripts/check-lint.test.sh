#!/usr/bin/env bash
# check-lint.test.sh: mutation self-test for check-lint.sh.
#
# Every case builds a throwaway tree under mktemp, runs the lint script on it and compares the exit
# code (and, for failures, that the output names the offending rule). There is one failing fixture
# per rule R1 to R6, plus passing cases that guard against false positives.
#
# Works on macOS bash 3.2 and Ubuntu bash 5.

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
LINT="$HERE/check-lint.sh"

TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

TOTAL=0
PASSED=0
CASE_NO=0

PIN='pragma solidity 0.8.35;'

# Clean fixture contents. Mutations are string replacements on these variables.
BOOK_CLEAN="// SPDX-License-Identifier: MIT
$PIN

contract LoanBook {
    function requestLoan(uint256 amount) external nonReentrant returns (uint256 id) {
        id = amount;
    }

    function getLoan(uint256 id) external view returns (uint256) {
        return id;
    }

    function _helper() private {}
}
"

TOKEN_CLEAN="// SPDX-License-Identifier: MIT
$PIN

import {AccessControl} from \"@openzeppelin/contracts/access/AccessControl.sol\";

contract MockStablecoin is AccessControl {
    function mint(uint256 amount) external {}
}
"

EVENTS_CLEAN="// SPDX-License-Identifier: MIT
$PIN

interface ILoanEvents {
    event LoanRequested(uint256 indexed loanId);
}
"

DEPLOY_CLEAN="// SPDX-License-Identifier: MIT
$PIN

contract Deploy {
    function run() external {
        vm.startBroadcast();
        vm.stopBroadcast();
    }
}
"

# make_tree DIR: write the clean tree.
make_tree() {
  mkdir -p "$1/src/interfaces" "$1/script"
  printf '%s' "$BOOK_CLEAN" > "$1/src/LoanBook.sol"
  printf '%s' "$TOKEN_CLEAN" > "$1/src/MockStablecoin.sol"
  printf '%s' "$EVENTS_CLEAN" > "$1/src/interfaces/ILoanEvents.sol"
  printf '%s' "$DEPLOY_CLEAN" > "$1/script/Deploy.s.sol"
}

# mut FILE BASE OLD NEW: write BASE to FILE with the first literal OLD replaced by NEW. Literal
# replacement through awk and ENVIRON, so braces and quotes need no escaping and it behaves the same
# on bash 3.2 and bash 5. A mutation that does not apply stops the suite, so no case can pass
# against an unmutated fixture by accident.
mut() {
  BASE="$2" OLD="$3" NEW="$4" awk 'BEGIN {
    t = ENVIRON["BASE"]; o = ENVIRON["OLD"]; n = ENVIRON["NEW"]
    i = index(t, o)
    if (i == 0) { exit 3 }
    printf "%s%s%s", substr(t, 1, i - 1), n, substr(t, i + length(o))
  }' > "$1" || {
    echo "FATAL: mutation did not apply: $3" >&2
    exit 2
  }
}

# fresh NAME: new clean tree, echoes its path.
fresh() {
  make_tree "$TMP_ROOT/$1"
  echo "$TMP_ROOT/$1"
}

# expect NAME EXPECTED_EXIT DIR [PATTERN]: PATTERN is a fixed string that the output must contain.
expect() {
  TOTAL=$((TOTAL + 1))
  bash "$LINT" "$3" > "$TMP_ROOT/out.txt" 2>&1
  code=$?
  verdict=ok
  if [ "$code" -ne "$2" ]; then
    verdict="exit $code, expected $2"
  elif [ -n "${4:-}" ] && ! grep -qF -- "$4" "$TMP_ROOT/out.txt"; then
    verdict="output lacks '$4'"
  fi
  if [ "$verdict" = ok ]; then
    PASSED=$((PASSED + 1))
    echo "PASS $TOTAL $1"
  else
    echo "FAIL $TOTAL $1 ($verdict)"
    sed 's/^/    /' "$TMP_ROOT/out.txt"
  fi
}

# --- clean tree and R1: pragma ---
d=$(fresh clean)
expect "clean tree exits 0 and prints lint: ok" 0 "$d" "lint: ok"

d=$(fresh r1-caret)
mut "$d/src/LoanBook.sol" "$BOOK_CLEAN" "$PIN" "pragma solidity ^0.8.35;"
expect "R1 caret pragma exits 1" 1 "$d" "pragma"

d=$(fresh r1-range)
mut "$d/src/LoanBook.sol" "$BOOK_CLEAN" "$PIN" "pragma solidity >=0.8.20 <0.9.0;"
expect "R1 range pragma exits 1" 1 "$d" "pragma"

d=$(fresh r1-missing)
mut "$d/src/MockStablecoin.sol" "$TOKEN_CLEAN" "$PIN" ""
expect "R1 missing pragma exits 1" 1 "$d" "missing"

d=$(fresh r1-other-file)
mut "$d/src/interfaces/ILoanEvents.sol" "$EVENTS_CLEAN" "$PIN" "pragma solidity ^0.8.0;"
expect "R1 loose pragma in a nested file exits 1" 1 "$d" "ILoanEvents.sol"

# --- R2: banned constructs ---
d=$(fresh r2-safemath)
mut "$d/src/LoanBook.sol" "$BOOK_CLEAN" "function _helper() private {}" "// SafeMath is not used here.
    function _helper() private {}"
expect "R2 a comment that says SafeMath exits 1" 1 "$d" "SafeMath"

d=$(fresh r2-unchecked)
mut "$d/src/LoanBook.sol" "$BOOK_CLEAN" "id = amount;" "unchecked { id = amount + 1; }"
expect "R2 an unchecked block exits 1" 1 "$d" "unchecked"

# --- R3: custom errors only ---
d=$(fresh r3-require-string)
mut "$d/src/LoanBook.sol" "$BOOK_CLEAN" "id = amount;" 'require(amount > 0, "zero"); id = amount;'
expect "R3 a require with a string exits 1" 1 "$d" "require"

d=$(fresh r3-require-multiline)
mut "$d/src/LoanBook.sol" "$BOOK_CLEAN" "id = amount;" 'require(
            amount > 0,
            "zero"
        );
        id = amount;'
expect "R3 a require with a string over several lines exits 1" 1 "$d" "require"

d=$(fresh r3-require-custom)
mut "$d/src/LoanBook.sol" "$BOOK_CLEAN" "id = amount;" "require(amount > 0, ZeroAmount()); id = amount;"
expect "R3 a require with a custom error exits 0" 0 "$d" "lint: ok"

# --- R4: nonReentrant presence ---
d=$(fresh r4-missing-guard)
mut "$d/src/LoanBook.sol" "$BOOK_CLEAN" "external nonReentrant returns" "external returns"
expect "R4 a state-changing external function without the guard exits 1" 1 "$d" "nonReentrant"

d=$(fresh r4-public-missing-guard)
mut "$d/src/LoanBook.sol" "$BOOK_CLEAN" "external nonReentrant returns" "public returns"
expect "R4 a state-changing public function without the guard exits 1" 1 "$d" "nonReentrant"

d=$(fresh r4-guard-second-line)
mut "$d/src/LoanBook.sol" "$BOOK_CLEAN" "function requestLoan(uint256 amount) external nonReentrant returns (uint256 id) {" "function requestLoan(
        uint256 amount
    ) external
        nonReentrant
        returns (uint256 id)
    {"
expect "R4 the guard on a later header line exits 0" 0 "$d" "lint: ok"

d=$(fresh r4-multiline-missing-guard)
mut "$d/src/LoanBook.sol" "$BOOK_CLEAN" "function requestLoan(uint256 amount) external nonReentrant returns (uint256 id) {" "function requestLoan(
        uint256 amount
    ) external
        returns (uint256 id)
    {"
expect "R4 a multi-line header without the guard exits 1" 1 "$d" "nonReentrant"

d=$(fresh r4-comment-guard)
mut "$d/src/LoanBook.sol" "$BOOK_CLEAN" "external nonReentrant returns (uint256 id) {" "external returns (uint256 id) { // nonReentrant"
expect "R4 a guard that only appears in a comment exits 1" 1 "$d" "nonReentrant"

d=$(fresh r4-view-no-guard)
expect "R4 a view function without the guard exits 0" 0 "$d" "lint: ok"

d=$(fresh r4-no-functions)
printf '%s\n%s\n' "// SPDX-License-Identifier: MIT" "$PIN" > "$d/src/LoanBook.sol"
expect "R4 a LoanBook with no function at all exits 1" 1 "$d" "scan"

# --- R5: no key reads in script/ ---
d=$(fresh r5-env-key)
mut "$d/script/Deploy.s.sol" "$DEPLOY_CLEAN" "vm.startBroadcast();" 'uint256 k = vm.envUint("DEPLOYER_KEY");
        vm.startBroadcast();'
expect "R5 an environment key read exits 1" 1 "$d" "key material"

d=$(fresh r5-broadcast-arg)
mut "$d/script/Deploy.s.sol" "$DEPLOY_CLEAN" "vm.startBroadcast();" "vm.startBroadcast(deployerKey);"
expect "R5 startBroadcast with an argument exits 1" 1 "$d" "startBroadcast"

d=$(fresh r5-broadcast-arg-multiline)
mut "$d/script/Deploy.s.sol" "$DEPLOY_CLEAN" "vm.startBroadcast();" "vm.startBroadcast(
            deployerKey
        );"
expect "R5 startBroadcast with an argument on the next line exits 1" 1 "$d" "startBroadcast"

# --- R6: no admin surface ---
d=$(fresh r6-ownable)
mut "$d/src/LoanBook.sol" "$BOOK_CLEAN" "contract LoanBook {" 'import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract LoanBook is Ownable {'
expect "R6 an Ownable import in LoanBook exits 1" 1 "$d" "admin surface"

d=$(fresh r6-delegatecall-nested)
mut "$d/src/interfaces/ILoanEvents.sol" "$EVENTS_CLEAN" "interface ILoanEvents {" "/// uses delegatecall
interface ILoanEvents {"
expect "R6 delegatecall in another src file exits 1" 1 "$d" "ILoanEvents.sol"

d=$(fresh r6-token-access-control)
expect "R6 AccessControl in MockStablecoin exits 0" 0 "$d" "lint: ok"

d=$(fresh r6-withdraw)
mut "$d/src/LoanBook.sol" "$BOOK_CLEAN" "function _helper() private {}" "function withdraw(uint256 amount) external nonReentrant {}"
expect "R6 a function named withdraw in LoanBook exits 1" 1 "$d" "custody"

d=$(fresh r6-pause)
mut "$d/src/LoanBook.sol" "$BOOK_CLEAN" "function _helper() private {}" "function pause() external nonReentrant {}"
expect "R6 a function named pause in LoanBook exits 1" 1 "$d" "custody"

# --- exit code 2 ---
d="$TMP_ROOT/no-src"
mkdir -p "$d/script" "$d/src"
printf '%s' "$DEPLOY_CLEAN" > "$d/script/Deploy.s.sol"
expect "a tree with no Solidity under src/ exits 2" 2 "$d"

d="$TMP_ROOT/no-src-dir"
mkdir -p "$d/script"
expect "a tree without a src/ directory exits 2" 2 "$d"

# --- every rule runs even after the first finding ---
d=$(fresh multi)
mut "$d/src/LoanBook.sol" "$BOOK_CLEAN" "$PIN" "pragma solidity ^0.8.35;"
mut "$d/script/Deploy.s.sol" "$DEPLOY_CLEAN" "vm.startBroadcast();" "vm.startBroadcast(k);"
TOTAL=$((TOTAL + 1))
bash "$LINT" "$d" > "$TMP_ROOT/out.txt" 2>&1
code=$?
if [ "$code" -eq 1 ] && grep -q 'LoanBook.sol' "$TMP_ROOT/out.txt" && grep -q 'Deploy.s.sol' "$TMP_ROOT/out.txt"; then
  PASSED=$((PASSED + 1))
  echo "PASS $TOTAL two findings in two places are both reported"
else
  echo "FAIL $TOTAL two findings in two places are both reported (exit $code)"
  sed 's/^/    /' "$TMP_ROOT/out.txt"
fi

echo "PASS $PASSED/$TOTAL"
[ "$PASSED" -eq "$TOTAL" ]
