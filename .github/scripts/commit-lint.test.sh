#!/usr/bin/env bash
# commit-lint.test.sh: fixture suite for commit-lint.sh.
# Builds throwaway git repositories, runs the lint script against chosen commit
# messages and branch names, and compares the exit code with the expectation.
# No network. Portable to macOS bash 3.2 and Ubuntu bash 5.

set -u
export LC_ALL=C

HERE=$(cd "$(dirname "$0")" && pwd)
LINT="$HERE/commit-lint.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

TOTAL=0
GOOD=0
BASE=""

new_repo() {
  rm -rf "$TMP/repo"
  mkdir "$TMP/repo"
  cd "$TMP/repo" || exit 2
  git init -q
  git config user.email "test@example.com"
  git config user.name "Test"
  git config commit.gpgsign false
  git commit -q --allow-empty -m "chore: init"
  BASE=$(git rev-parse HEAD)
  : > "$TMP/ignore.txt"
}

commit_msg() {
  printf '%s' "$1" > "$TMP/msg"
  git commit -q --allow-empty -F "$TMP/msg"
}

repeat_char() {
  # repeat_char CHAR COUNT
  out=""
  i=0
  while [ "$i" -lt "$2" ]; do
    out="${out}$1"
    i=$((i + 1))
  done
  printf '%s' "$out"
}

# expect NAME EXPECTED_EXIT [VAR=value ...]
expect() {
  name="$1"
  want="$2"
  shift 2
  TOTAL=$((TOTAL + 1))
  env BASE_SHA="$BASE" HEAD_SHA=HEAD IGNORE_FILE="$TMP/ignore.txt" "$@" bash "$LINT" > "$TMP/out.txt" 2>&1
  got=$?
  if [ "$got" -eq "$want" ]; then
    GOOD=$((GOOD + 1))
    echo "ok $TOTAL $name"
  else
    echo "not ok $TOTAL $name (expected exit $want, got $got)"
    sed 's/^/    /' "$TMP/out.txt"
  fi
}

# Helper: new repo with one commit message, then expect.
case_commit() {
  # case_commit NAME EXPECTED_EXIT MESSAGE [VAR=value ...]
  name="$1"
  want="$2"
  msg="$3"
  shift 3
  new_repo
  commit_msg "$msg"
  expect "$name" "$want" "$@"
}

# ---------------------------------------------------------------- pass cases
case_commit "pass plain feat subject" 0 "feat: add loan request form"
case_commit "pass scoped fix" 0 "fix(api): reject empty amount"
case_commit "pass breaking marker with scope" 0 "feat(api)!: drop the v1 endpoints"
case_commit "pass multi-line message with body" 0 "refactor(core): split the service

The service grew past 500 lines, so each concern now has its own class.
No behavior change."
case_commit "pass chore with dotted scope" 0 "chore(deps.dev): bump the test runner"
case_commit "pass GitHub revert subject" 0 'Revert "feat: add loan request form"'
case_commit "pass human co-author trailer" 0 "feat: pair on the repayment flow

Co-authored-by: Ana Torres <ana@example.com>"

new_repo
git checkout -q -b side
commit_msg "feat: work on the side branch"
git checkout -q -
commit_msg "fix: work on the main line"
git merge -q --no-ff side -m "Merge branch 'side' into main" > /dev/null 2>&1
expect "pass merge commit with non-conforming subject is skipped" 0

new_repo
commit_msg "bad subject that is ignored on purpose"
git rev-parse HEAD > "$TMP/ignore.txt"
expect "pass non-conforming commit listed in the ignore file" 0

case_commit "pass valid PR title" 0 "feat: add a thing" PR_TITLE="feat(api): add the repayment endpoint"
case_commit "pass base develop with head feature slug" 0 "feat: add a thing" HEAD_REF="feature/login-flow" BASE_REF="develop"
case_commit "pass base main with head release/0.1.0" 0 "feat: add a thing" HEAD_REF="release/0.1.0" BASE_REF="main"
case_commit "pass base main with head hotfix/1.0.1" 0 "feat: add a thing" HEAD_REF="hotfix/1.0.1" BASE_REF="main"

# ---------------------------------------------------------------- fail cases
case_commit "fail subject without type" 1 "add loan request form"
case_commit "fail missing space after the colon" 1 "feat:add loan request form"
case_commit "fail type spelled feature" 1 "feature: add loan request form"
case_commit "fail capitalized type" 1 "Feat: add loan request form"
case_commit "fail empty scope parentheses" 1 "feat(): add loan request form"
LONG="feat: $(repeat_char x 95)"
case_commit "fail 101-character subject" 1 "$LONG"
case_commit "fail co-author trailer naming Claude" 1 "feat: add a thing

Co-Authored-By: Claude <noreply@example.com>"
case_commit "fail co-author trailer with mixed case and an anthropic address" 1 "feat: add a thing

CO-authored-BY: Some Assistant <noreply@anthropic.com>"
case_commit "fail Copilot co-author trailer" 1 "feat: add a thing

Co-authored-by: GitHub Copilot <copilot@example.com>"
case_commit "fail generated-with line naming Claude Code" 1 "feat: add a thing

Generated with Claude Code"
case_commit "fail openai noreply address in the body" 1 "feat: add a thing

Reviewed by bot <noreply@openai.com>"
case_commit "fail malformed PR title" 1 "feat: add a thing" PR_TITLE="Add the repayment endpoint"
case_commit "fail base develop with head fix/typo" 1 "feat: add a thing" HEAD_REF="fix/typo" BASE_REF="develop"
case_commit "fail base main with head feature/x" 1 "feat: add a thing" HEAD_REF="feature/x" BASE_REF="main"
case_commit "fail base develop with head main" 1 "feat: add a thing" HEAD_REF="main" BASE_REF="develop"

# ------------------------------------------------------------ interface cases
new_repo
commit_msg "oops no type"
BAD=$(git rev-parse HEAD)
TOTAL=$((TOTAL + 1))
printed=$(env BASE_SHA="$BASE" HEAD_SHA=HEAD IGNORE_FILE="$TMP/ignore.txt" bash "$LINT" --print-violating-shas 2> /dev/null)
rc=$?
if [ "$rc" -eq 0 ] && [ "$printed" = "$BAD" ]; then
  GOOD=$((GOOD + 1))
  echo "ok $TOTAL print-violating-shas lists the full SHA and exits 0"
else
  echo "not ok $TOTAL print-violating-shas lists the full SHA and exits 0 (rc=$rc, printed '$printed')"
fi

new_repo
commit_msg "feat: fine"
expect "usage error exits 2 when BASE_SHA is missing" 2 BASE_SHA=""

new_repo
commit_msg "oops no type"
expect "ROOT base lints the whole history and fails" 1 BASE_SHA=ROOT

echo "PASS $GOOD/$TOTAL"
[ "$GOOD" -eq "$TOTAL" ]
