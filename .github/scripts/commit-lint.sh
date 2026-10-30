#!/usr/bin/env bash
# commit-lint.sh: Conventional Commits, AI attribution and GitFlow branch policy.
#
# Inputs (environment variables):
#   BASE_SHA     required. Exclusive lower bound of the range, or the literal ROOT
#                to lint the whole history reachable from HEAD_SHA.
#   HEAD_SHA     required. Inclusive upper bound of the range.
#   PR_TITLE     optional. When empty, rule R4 is skipped.
#   HEAD_REF     optional. Source branch of the pull request.
#   BASE_REF     optional. Target branch of the pull request.
#   IGNORE_FILE  optional. Defaults to .github/commit-lint-ignore.txt.
#
# Flags:
#   --print-violating-shas  print the full SHAs that violate R1 to R3, one per line, exit 0.
#
# Rules:
#   R1 subject format      type(scope)!: text, GitHub revert subjects are accepted
#   R2 subject length      at most 100 characters
#   R3 AI attribution      no AI co-author trailer, no generated-with line, no AI noreply address
#   R4 pull request title  must satisfy R1 and R2 (squash merges reuse it as the subject)
#   R5 branch policy       GitFlow naming for the head branch given the base branch
#
# Exit codes: 0 clean, 1 violations found, 2 usage error.
# Portable to macOS bash 3.2 and Ubuntu bash 5: no mapfile, no associative arrays.

set -u
export LC_ALL=C

PRINT_SHAS=0
if [ "${1:-}" = "--print-violating-shas" ]; then
  PRINT_SHAS=1
  shift
fi
if [ "$#" -gt 0 ]; then
  echo "commit-lint: usage error: unexpected argument '$1'" >&2
  exit 2
fi

BASE_SHA="${BASE_SHA:-}"
HEAD_SHA="${HEAD_SHA:-}"
PR_TITLE="${PR_TITLE:-}"
HEAD_REF="${HEAD_REF:-}"
BASE_REF="${BASE_REF:-}"
IGNORE_FILE="${IGNORE_FILE:-.github/commit-lint-ignore.txt}"

if [ -z "$BASE_SHA" ] || [ -z "$HEAD_SHA" ]; then
  echo "commit-lint: usage error: BASE_SHA and HEAD_SHA are required" >&2
  exit 2
fi

TYPES='feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert'
SUBJECT_RE="^(${TYPES})(\\([a-z0-9._/,-]+\\))?!?: [^ ].*$"
REVERT_RE='^Revert ".+"$'
AI_NAMES='claude|anthropic|openai|chatgpt|gpt|copilot|gemini|codex|cursor|devin|aider|windsurf|ai assistant'
AI_TOKEN_RE="(^|[^a-z0-9])(${AI_NAMES})([^a-z0-9]|\$)"
SLUG='[a-z0-9._-]+'

VIOLATIONS=0
CHECKED=0

report() {
  # report TARGET RULE MESSAGE
  VIOLATIONS=$((VIOLATIONS + 1))
  if [ "$PRINT_SHAS" -eq 0 ]; then
    echo "commit-lint: FAIL $1 $2 $3"
  fi
}

# Returns 0 when the subject satisfies R1.
subject_ok() {
  if printf '%s\n' "$1" | grep -Eq "$SUBJECT_RE"; then
    return 0
  fi
  if printf '%s\n' "$1" | grep -Eq "$REVERT_RE"; then
    return 0
  fi
  return 1
}

is_ignored() {
  # is_ignored FULL_SHA
  [ -f "$IGNORE_FILE" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      '' | '#'*) continue ;;
    esac
    tok="${line%%[[:space:]]*}"
    [ -n "$tok" ] || continue
    if [ "${#tok}" -ge 7 ]; then
      case "$1" in
        "$tok"*) return 0 ;;
      esac
    fi
  done < "$IGNORE_FILE"
  return 1
}

if [ "$BASE_SHA" = "ROOT" ]; then
  RANGE="$HEAD_SHA"
else
  RANGE="${BASE_SHA}..${HEAD_SHA}"
fi

if ! SHAS=$(git rev-list --no-merges "$RANGE" 2>/dev/null); then
  echo "commit-lint: usage error: cannot resolve range $RANGE" >&2
  exit 2
fi

for sha in $SHAS; do
  if is_ignored "$sha"; then
    continue
  fi
  CHECKED=$((CHECKED + 1))
  short=$(printf '%s' "$sha" | cut -c1-7)
  msg=$(git log -1 --format=%B "$sha")
  subject=$(printf '%s\n' "$msg" | sed -n '1p')
  before=$VIOLATIONS

  if ! subject_ok "$subject"; then
    report "$short" R1 "subject must look like 'type(scope): text' with type in ${TYPES}"
  fi
  if [ "${#subject}" -gt 100 ]; then
    report "$short" R2 "subject is ${#subject} characters, the limit is 100"
  fi

  # R3: AI attribution.
  lower=$(printf '%s\n' "$msg" | tr '[:upper:]' '[:lower:]')
  if printf '%s\n' "$lower" | grep -E '^co-authored-by:' | grep -Eq "$AI_TOKEN_RE"; then
    report "$short" R3 "AI co-author trailer found"
  fi
  if printf '%s\n' "$lower" | grep -E 'generated (with|by)' | grep -Eq "$AI_TOKEN_RE"; then
    report "$short" R3 "AI generated-with line found"
  fi
  if printf '%s\n' "$lower" | grep -Eq 'noreply@(anthropic|openai)\.com'; then
    report "$short" R3 "AI noreply address found"
  fi

  if [ "$PRINT_SHAS" -eq 1 ] && [ "$VIOLATIONS" -gt "$before" ]; then
    case "${SHA_HITS:-}" in
      *"$sha"*) ;;
      *) SHA_HITS="${SHA_HITS:-}${sha}
" ;;
    esac
  fi
done

# R4: pull request title.
if [ -n "$PR_TITLE" ]; then
  if ! subject_ok "$PR_TITLE"; then
    report PR R4 "pull request title must look like 'type(scope): text'"
  fi
  if [ "${#PR_TITLE}" -gt 100 ]; then
    report PR R4 "pull request title is ${#PR_TITLE} characters, the limit is 100"
  fi
elif [ "$PRINT_SHAS" -eq 0 ]; then
  echo "commit-lint: skipped R4 (PR_TITLE not set)"
fi

# R5: GitFlow branch policy.
if [ -n "$HEAD_REF" ] && [ -n "$BASE_REF" ]; then
  case "$BASE_REF" in
    develop)
      if ! printf '%s\n' "$HEAD_REF" | grep -Eq "^(feature|release|hotfix)/${SLUG}\$"; then
        report BRANCH R5 "into develop only feature/*, release/* or hotfix/* with a lowercase slug are allowed, got '${HEAD_REF}'"
      fi
      ;;
    main)
      if ! printf '%s\n' "$HEAD_REF" | grep -Eq "^(release|hotfix)/${SLUG}\$"; then
        report BRANCH R5 "into main only release/* or hotfix/* with a lowercase slug are allowed, got '${HEAD_REF}'"
      fi
      ;;
    *)
      if [ "$PRINT_SHAS" -eq 0 ]; then
        echo "commit-lint: skipped R5 (base branch '${BASE_REF}' is not governed)"
      fi
      ;;
  esac
elif [ "$PRINT_SHAS" -eq 0 ]; then
  echo "commit-lint: skipped R5 (HEAD_REF or BASE_REF not set)"
fi

if [ "$PRINT_SHAS" -eq 1 ]; then
  printf '%s' "${SHA_HITS:-}"
  exit 0
fi

echo "commit-lint: ${CHECKED} commit(s) checked, ${VIOLATIONS} violation(s)"
if [ "$VIOLATIONS" -gt 0 ]; then
  exit 1
fi
exit 0
