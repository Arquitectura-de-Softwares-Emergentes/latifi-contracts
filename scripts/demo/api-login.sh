#!/usr/bin/env bash
# Signs in to the deployed LatiFi API with a Foundry keystore and stores the access token.
#
#   bash scripts/demo/api-login.sh --api-base https://HOST/api/v1 --account latifi-borrower
#
# Required:
#   --api-base URL     API base including /api/v1. Must be https, except for localhost.
#   --account NAME     Foundry keystore account name (cast wallet import NAME). The address is
#                      derived from it with `cast wallet address --account NAME`.
# Optional:
#   --token-file FILE  [~/.latifi/api-token] written with mode 600 (created under umask 077)
#
# Flow: POST /auth/challenge, sign the exact message text with `cast wallet sign --account NAME`
# (cast asks for the keystore password itself, on the terminal, once for the address and once for
# the signature), POST /auth/verify, store the
# token. The script prints only `login-ok ADDRESS expiresIn=SECONDS`. It never prints the token or
# the signature, has no flag for a password or a key, and keeps the signature and the token out
# of every command line (request bodies go through stdin).
#
# The token lives 15 minutes and there is no refresh token. Run the script again when it expires.
#
# Exit codes: 0 signed in, 2 bad usage, 3 the API is unreachable, 5 the API refused the sign in.
# Needs cast, curl and jq. Compatible with bash 3.2.
set -euo pipefail

die() {
  local code="$1"
  shift
  echo "api-login: $*" >&2
  exit "$code"
}

api_base=""
account=""
token_file="${LATIFI_HOME:-$HOME/.latifi}/api-token"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --api-base | --account | --token-file)
      [ "$#" -ge 2 ] || die 2 "$1 needs a value"
      case "$2" in -*) die 2 "$1 needs a value, got '$2'" ;; esac
      case "$1" in
        --api-base) api_base="$2" ;;
        --account) account="$2" ;;
        --token-file) token_file="$2" ;;
      esac
      shift 2
      ;;
    -h | --help)
      sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) die 2 "unknown argument '$1' (there is no flag for a password or a key)" ;;
  esac
done

[ -n "$api_base" ] || die 2 "--api-base is required"
[ -n "$account" ] || die 2 "--account is required"
printf '%s' "$account" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$' || die 2 "--account must be a keystore name, not a path"
for tool in cast curl jq; do
  command -v "$tool" >/dev/null 2>&1 || die 2 "$tool is not installed"
done

api_base="${api_base%/}"
case "$api_base" in
  https://*) ;;
  http://localhost | http://localhost/* | http://localhost:* | http://127.0.0.1 | http://127.0.0.1/* | http://127.0.0.1:*) ;;
  *) die 2 "the API base must be https (http is allowed for localhost only)" ;;
esac

echo "api-login: cast reads the keystore '$account' and asks for its password (twice: address, then signature)" >&2
address="$(cast wallet address --account "$account" 2>/dev/null)" || die 2 "cast could not read the keystore account '$account'"
printf '%s' "$address" | grep -Eq '^0x[0-9a-fA-F]{40}$' || die 2 "cast returned an unexpected address for '$account'"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
chmod 700 "$work"

# post URL OUTFILE (JSON on stdin) : prints the HTTP status. The body goes through stdin.
post() {
  local code
  code="$(curl -sS --max-time 20 -o "$2" -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' -H 'Accept: application/json' \
    --data-binary @- "$1" 2>/dev/null || true)"
  case "$code" in [0-9][0-9][0-9]) printf '%s' "$code" ;; *) printf '000' ;; esac
}

status="$(jq -n --arg a "$address" '{address: $a}' | post "$api_base/auth/challenge" "$work/challenge.json")"
case "$status" in
  200) ;;
  000) die 3 "the API is unreachable" ;;
  *) die 5 "the challenge request was refused (HTTP $status)" ;;
esac
challenge_id="$(jq -r '.challengeId // empty' "$work/challenge.json")"
[ -n "$challenge_id" ] || die 5 "the challenge answer has no challengeId"
jq -e '.message | type == "string" and length > 0' "$work/challenge.json" >/dev/null 2>&1 || die 5 "the challenge answer has no message"
# -j prints the message with its line feeds and without an added trailing newline.
message="$(jq -j '.message' "$work/challenge.json")"

signature="$(cast wallet sign --account "$account" "$message")" || die 2 "signing failed"
sig_re='^0x[0-9a-fA-F]{130}$'
[[ "$signature" =~ $sig_re ]] || die 2 "cast returned an unexpected signature"

status="$(jq -n --arg id "$challenge_id" --arg a "$address" --arg s "$signature" \
  '{challengeId: $id, address: $a, signature: $s}' | post "$api_base/auth/verify" "$work/verify.json")"
signature=""
case "$status" in
  200) ;;
  000) die 3 "the API is unreachable" ;;
  *) die 5 "the sign in was refused (HTTP $status). The challenge lives 5 minutes, run the script again" ;;
esac
jq -e '(.accessToken | type == "string" and length > 0) and (.expiresIn | type == "number")' "$work/verify.json" >/dev/null 2>&1 ||
  die 5 "the verify answer is missing the token or expiresIn"

dir="$(dirname "$token_file")"
(umask 077 && mkdir -p "$dir") || die 2 "cannot create $dir"
tmp="$(umask 077 && mktemp "$dir/.api-token.XXXXXX")" || die 2 "cannot write in $dir"
jq -j '.accessToken' "$work/verify.json" >"$tmp"
chmod 600 "$tmp"
mv "$tmp" "$token_file"

printf 'login-ok %s expiresIn=%s\n' "$address" "$(jq -r '.expiresIn' "$work/verify.json")"
