#!/usr/bin/env bash
# Offline tests for the demo scripts (api-login.sh, verify-run.sh, rpc-fault-proxy.py).
# A stub `cast`, a stub `curl` and a local stub upstream stand in for the network, so the suite
# needs no RPC, no API, no keys and no funds. Run from anywhere. Needs jq and python3.
# Compatible with bash 3.2.
# Prints `demo-test: ok N cases` and exits 0, or prints the failing case and exits 1 at once.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PYTHONDONTWRITEBYTECODE=1
WORK="$(mktemp -d)"
PIDS=""
cleanup() {
  local f
  for p in $PIDS; do kill "$p" 2>/dev/null || true; done
  # start_proxy runs inside a command substitution, so it records its process id in a file.
  for f in "$WORK"/*.pid; do
    [ ! -f "$f" ] || kill "$(cat "$f")" 2>/dev/null || true
  done
  rm -rf "$WORK"
}
trap cleanup EXIT

RPC_CANARY="https://rpc.example.invalid/v2/CANARYKEYCANARYKEY0123456789"
PW_CANARY="PWCANARY-never-print-this"
TOKEN_CANARY="TOKENCANARY.eyJhbGciOiJIUzI1NiJ9.payload.sig"
SIG_BODY="5ca1ab1e5ca1ab1e5ca1ab1e5ca1ab1e5ca1ab1e5ca1ab1e5ca1ab1e5ca1ab1e5ca1ab1e5ca1ab1e5ca1ab1e5ca1ab1e5ca1ab1e5ca1ab1e5ca1ab1e5ca1ab1e5ca1ab1e5c"
SIG_CANARY="0x$(printf '%s' "$SIG_BODY" | cut -c1-130)"
SIG_MARK="5ca1ab1e5ca1ab1e"
ST="$WORK/state"
mkdir -p "$WORK/bin" "$ST/api" "$ST/accounts" "$WORK/home"

# ---------------------------------------------------------------- stub cast
# Answers chain-id, call (getLoan), wallet address and wallet sign. Logs every call. Fails the
# suite on a leaked RPC URL, a raw key or a password argument.
cat >"$WORK/bin/cast" <<'STUB'
#!/usr/bin/env bash
echo "cast $*" >>"$STUB_LOG"
case "$*" in *rpc.example.invalid*) echo "stub: rpc url leaked into argv" >&2; exit 9 ;; esac
case "$*" in *--private-key* | *--mnemonic* | *--password\ * | *--unlocked*)
  echo "stub: a raw key or password argument was passed" >&2; exit 9 ;; esac
case "$*" in *PWCANARY*) echo "stub: a password was passed on the command line" >&2; exit 9 ;; esac
case "$1" in chain-id | call)
  [ -n "${ETH_RPC_URL:-}" ] || { echo "stub: ETH_RPC_URL missing" >&2; exit 9; } ;;
esac
case "$1" in
  chain-id)
    [ -z "${STUB_RPC_DOWN:-}" ] || { echo "connection refused for $ETH_RPC_URL" >&2; exit 1; }
    echo "${STUB_NETWORK:-80002}" ;;
  call)
    [ -z "${STUB_CALL_FAIL:-}" ] || { echo "execution reverted at $ETH_RPC_URL" >&2; exit 1; }
    [ "$3" = "getLoan(uint256)((address,uint16,uint32,uint8,uint8,address,uint64,uint128,uint128,uint128))" ] ||
      { echo "stub: unknown call $3" >&2; exit 8; }
    cat "$STUB_STATE/loan" ;;
  wallet)
    name=""
    prev=""
    for a in "$@"; do
      case "$prev" in --account) name="$a" ;; esac
      prev="$a"
    done
    [ -f "$STUB_STATE/accounts/$name" ] || { echo "stub: no such account" >&2; exit 1; }
    case "$2" in
      address) cat "$STUB_STATE/accounts/$name" ;;
      sign)
        eval "last=\"\${$#}\""
        printf '%s' "$last" >"$STUB_STATE/signed-message"
        cat "$STUB_STATE/signature" ;;
      *) exit 8 ;;
    esac ;;
  *) exit 8 ;;
esac
STUB
chmod +x "$WORK/bin/cast"

# ---------------------------------------------------------------- stub curl
# Serves files from $STUB_STATE/api by path (query string dropped, lower case, non alphanumerics
# become underscores). A <key>.code file sets the HTTP status. A <key>.queue directory serves its
# numbered files one per request and keeps the last. Fails on a secret in argv.
cat >"$WORK/bin/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl $*" >>"$STUB_LOG"
case "$*" in *TOKENCANARY* | *5ca1ab1e5ca1ab1e* | *PWCANARY*)
  echo "stub: a secret reached the curl command line" >&2; exit 9 ;; esac
out=""
url=""
read_cfg=0
read_body=0
prev=""
for a in "$@"; do
  case "$prev" in
    -o) out="$a" ;;
    -K) [ "$a" = "-" ] && read_cfg=1 ;;
    --data-binary) [ "$a" = "@-" ] && read_body=1 ;;
  esac
  case "$a" in http://* | https://*) url="$a" ;; esac
  prev="$a"
done
[ -z "$url" ] || echo "$url" >>"$STUB_STATE/urls"
[ "$read_cfg" -eq 0 ] || cat >"$STUB_STATE/last-config"
[ "$read_body" -eq 0 ] || cat >"$STUB_STATE/last-body"
[ -z "${STUB_API_DOWN:-}" ] || exit 7
path="${url#*://}"
path="/${path#*/}"
path="${path%%\?*}"
key="$(printf '%s' "${path#/api/v1/}" | tr 'A-Z' 'a-z' | sed 's#[^a-z0-9]#_#g')"
code=200
[ ! -f "$STUB_STATE/api/$key.code" ] || code="$(cat "$STUB_STATE/api/$key.code")"
if [ -d "$STUB_STATE/api/$key.queue" ]; then
  first="$(ls "$STUB_STATE/api/$key.queue" | sort -n | head -n 1)"
  cat "$STUB_STATE/api/$key.queue/$first" >"$out"
  [ "$(ls "$STUB_STATE/api/$key.queue" | wc -l)" -le 1 ] || rm -f "$STUB_STATE/api/$key.queue/$first"
elif [ -f "$STUB_STATE/api/$key.json" ]; then
  cat "$STUB_STATE/api/$key.json" >"$out"
else
  code=404
  echo '{}' >"$out"
fi
printf '%s' "$code"
STUB
chmod +x "$WORK/bin/curl"

export PATH="$WORK/bin:$PATH"
export STUB_LOG="$WORK/calls.log"
export STUB_STATE="$ST"
export LATIFI_HOME="$WORK/home/.latifi"
export AMOY_RPC_URL="$RPC_CANARY"
export ETH_PASSWORD="$PW_CANARY"
export VERIFY_POLL_INTERVAL=0.2
: >"$STUB_LOG"

# ---------------------------------------------------------------- harness

CASES=0
fail() {
  echo "demo-test: FAIL $1" >&2
  [ -z "${OUT:-}" ] || printf '%s\n' "$OUT" | sed 's/^/  | /' >&2
  exit 1
}
exit_is() { # name, expected exit
  CASES=$((CASES + 1))
  [ "$RC" = "$2" ] || fail "$1 (expected exit $2, got $RC)"
}
holds() { # name, command words that must succeed
  CASES=$((CASES + 1))
  local name="$1"
  shift
  "$@" >/dev/null 2>&1 || fail "$name"
}
eq() { # name, expected, actual
  CASES=$((CASES + 1))
  [ "$2" = "$3" ] || fail "$1 (expected '$2', got '$3')"
}
run() {
  OUT="$("$@" 2>&1)"
  RC=$?
}
# run_bounded CMD... : like run, but a command still alive after 4 seconds is killed and counts as
# exit 99. A proxy that should refuse to start but starts instead must fail the suite, not hang it.
run_bounded() {
  local log="$WORK/bounded.log" pid
  "$@" >"$log" 2>&1 &
  pid=$!
  for _ in $(seq 1 40); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    RC=99
  else
    wait "$pid"
    RC=$?
  fi
  OUT="$(cat "$log")"
}
has() { printf '%s' "$OUT" | grep -qF -- "$1"; }
ok_has() { CASES=$((CASES + 1)); has "$1" || fail "output lacks '$1'"; }
ok_not_has() { CASES=$((CASES + 1)); ! has "$1" || fail "output holds '$1'"; }
no_code_match() { # pattern, files: no match outside comment lines
  ! (grep -hv '^[[:space:]]*#' "${@:2}" | grep -Eq "$1")
}

LOGIN="$HERE/api-login.sh"
VERIFY="$HERE/verify-run.sh"
PROXY="$HERE/rpc-fault-proxy.py"

BORROWER="0xcb9003E7f369AE9b55C18D8cfEC8A32a12ee61F0"
BOOK="0xCCB8ad15a4954138c987a77924ceab468a843266"
BORROWER_KEY="$(printf '%s' "$BORROWER" | tr 'A-Z' 'a-z' | sed 's#[^a-z0-9]#_#g')"
API="https://api.example.invalid/api/v1"
printf '%s\n' "$BORROWER" >"$ST/accounts/latifi-borrower"
printf '%s\n' "$SIG_CANARY" >"$ST/signature"

# ---------------------------------------------------------------- 1. api-login.sh

CHALLENGE_MSG=$'api.example.invalid wants you to sign in with your Ethereum account:\n'"$BORROWER"$'\n\nSign in to LatiFi.\n\nURI: https://api.example.invalid\nNonce: 9c1d4f7a2b8e4d3f5a6b7c8d9e0f1a2b'
jq -n --arg m "$CHALLENGE_MSG" \
  '{challengeId: "3f2b8c1e-5d4a-4c7b-9a10-2e6f7d8c9b01", nonce: "9c1d", message: $m, issuedAt: "2026-01-01T12:00:00Z", expiresAt: "2026-01-01T12:05:00Z"}' \
  >"$ST/api/auth_challenge.json"
jq -n --arg t "$TOKEN_CANARY" --arg a "$BORROWER" \
  '{accessToken: $t, tokenType: "Bearer", expiresIn: 900, address: $a}' >"$ST/api/auth_verify.json"

TF="$WORK/home/new-dir/api-token"
STDOUT="$(bash "$LOGIN" --api-base "$API" --account latifi-borrower --token-file "$TF" 2>"$WORK/login.err")"
RC=$?
OUT="$STDOUT$(cat "$WORK/login.err")"
exit_is "login succeeds" 0
eq "login prints only the ok line on stdout" "login-ok $BORROWER expiresIn=900" "$STDOUT"
ok_not_has "$TOKEN_CANARY"
ok_not_has "$SIG_MARK"
ok_not_has "$PW_CANARY"
eq "the token file holds the token" "$TOKEN_CANARY" "$(cat "$TF")"
mode_of() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }
eq "the token file is mode 600" 600 "$(mode_of "$TF")"
eq "a new token folder is mode 700" 700 "$(mode_of "$WORK/home/new-dir")"
eq "the exact message was signed, line feeds kept" "$CHALLENGE_MSG" "$(cat "$ST/signed-message")"
eq "the verify body names the challenge" "3f2b8c1e-5d4a-4c7b-9a10-2e6f7d8c9b01" "$(jq -r .challengeId "$ST/last-body")"
eq "the verify body names the address" "$BORROWER" "$(jq -r .address "$ST/last-body")"
eq "the verify body carries the signature" "$SIG_CANARY" "$(jq -r .signature "$ST/last-body")"
holds "the account address came from cast" grep -q "cast wallet address --account latifi-borrower" "$STUB_LOG"
holds "the message was signed with the keystore account" grep -q "cast wallet sign --account latifi-borrower" "$STUB_LOG"

run bash "$LOGIN" --api-base http://api.example.invalid/api/v1 --account latifi-borrower --token-file "$WORK/t1"
exit_is "an http API base is refused" 2
ok_has "https"
[ ! -e "$WORK/t1" ] || fail "a refused run wrote a token file"
run bash "$LOGIN" --api-base http://localhost:8080/api/v1 --account latifi-borrower --token-file "$WORK/t2"
exit_is "an http localhost base is allowed" 0
run bash "$LOGIN" --api-base "$API" --account latifi-borrower --password hunter2
exit_is "there is no password flag" 2
run bash "$LOGIN" --api-base "$API" --account latifi-borrower --private-key 0xabc
exit_is "there is no key flag" 2
run bash "$LOGIN" --api-base "$API" --account /tmp/some/keystore
exit_is "an account must be a name and not a path" 2
run bash "$LOGIN" --api-base "$API"
exit_is "the account is required" 2
run bash "$LOGIN" --api-base "$API" --account no-such-account --token-file "$WORK/t3"
exit_is "an unknown keystore account is refused" 2
STUB_API_DOWN=1 run bash "$LOGIN" --api-base "$API" --account latifi-borrower --token-file "$WORK/t4"
exit_is "an unreachable API exits 3" 3
echo 401 >"$ST/api/auth_verify.code"
run bash "$LOGIN" --api-base "$API" --account latifi-borrower --token-file "$WORK/t5"
exit_is "a refused sign in exits 5" 5
ok_not_has "$TOKEN_CANARY"
ok_not_has "$SIG_MARK"
[ ! -e "$WORK/t5" ] || fail "a refused sign in wrote a token file"
rm -f "$ST/api/auth_verify.code"
holds "api-login has no password or key flag in code" no_code_match '(--password|--private-key|--mnemonic|--unlocked)' "$LOGIN"
holds "api-login never echoes the token or the signature" no_code_match '(echo|printf).*(\$\{?(token|signature)([^A-Za-z_]|$)|accessToken)' "$LOGIN"

# ---------------------------------------------------------------- 2. verify-run.sh

printf '%s' "$TOKEN_CANARY" >"$WORK/token"
chmod 600 "$WORK/token"
EV="$WORK/evidence.json"
TX1="0x$(printf '1%.0s' $(seq 1 64))"
TX2="0x$(printf '2%.0s' $(seq 1 64))"
TX3="0x$(printf '3%.0s' $(seq 1 64))"

# loan_tuple BORROWER INSTALLMENTS STATUS DUE PAID : the way cast prints getLoan.
set_chain() {
  printf '(%s, 1000 [1e3], 1, %s, %s, 0xA22412ba83539ACFd3385DA78F6214E800E865a3, 1762000000 [1.762e9], 100000000 [1e8], %s [1e8], %s [1e8])\n' \
    "$1" "$2" "$3" "$4" "$5" >"$ST/loan"
}
# set_api_loan ID STATUS DUE REPAID PAID_N
set_api_loan() {
  jq -n --arg id "$1" --arg s "$2" --arg due "$3" --arg rep "$4" --argjson n "$5" \
    '{loanId: $id, status: $s, totalDue: $due, amountRepaid: $rep, installmentsPaid: $n}' >"$ST/api/loans_$1.json"
}
set_reputation() { # score, level, onTime, late
  jq -n --arg a "$BORROWER" --argjson s "$1" --arg l "$2" --argjson o "$3" --argjson t "$4" \
    '{address: $a, score: $s, level: $l, onTimeCount: $o, lateCount: $t, defaultCount: 0, profileComplete: true, updatedAt: "2026-01-01T12:00:00Z"}' \
    >"$ST/api/reputation_$BORROWER_KEY.json"
}
# event ID LOAN TYPE DELTA AFTER DAYS TX LOGINDEX : one history entry as JSON
event() {
  jq -n --argjson id "$1" --arg loan "$2" --arg type "$3" --argjson d "$4" --argjson after "$5" \
    --arg days "$6" --arg tx "$7" --argjson li "$8" \
    '{id: $id, loanId: (if $loan == "" then null else $loan end), type: $type, delta: $d, scoreAfter: $after,
      daysLate: (if $days == "" then null else ($days | tonumber) end),
      txHash: (if $tx == "" then null else $tx end), logIndex: (if $tx == "" then null else $li end),
      occurredAt: "2026-01-01T12:00:00Z"}'
}
set_history() { # event JSON arguments
  printf '%s\n' "$@" | jq -s '{items: ., page: 0, size: 100, totalItems: length}' >"$ST/api/reputation_${BORROWER_KEY}_history.json"
}
profile="$(event 1 "" PROFILE_COMPLETED 50 550 "" "" 0)"

VR() {
  rm -f "$EV"
  run bash "$VERIFY" --api-base "$API" --token-file "$WORK/token" --book "$BOOK" --loan-id 7 \
    --borrower "$BORROWER" --wait 1 --evidence "$EV" "$@"
}
ev() { jq -r "$1" "$EV"; }

# Run A: a fresh borrower, two installments paid on time.
on_time_state() {
  set_chain "$BORROWER" 2 3 100027397 100027397
  set_api_loan 7 REPAID 100027397 100027397 2
  set_reputation 590 BUILDING 2 0
  set_history "$profile" "$(event 2 7 REPAID_ON_TIME 20 570 "" "$TX1" 3)" "$(event 3 7 REPAID_ON_TIME 20 590 "" "$TX2" 1)"
}
on_time_state
VR --expect-on-time
exit_is "a matching on time run passes" 0
ok_has "verify-run: ok loan 7"
ok_has "mirror matched after"
ok_has "REPAID_ON_TIME delta 20 score 590"
eq "evidence loan id" 7 "$(ev .loanId)"
eq "evidence chain status" REPAID "$(ev .chainStatus)"
eq "evidence API status" REPAID "$(ev .apiStatus)"
eq "evidence total due" 100027397 "$(ev .totalDue)"
eq "evidence installments paid" 2 "$(ev .installmentsPaid)"
eq "evidence score" 590 "$(ev .reputation.score)"
eq "evidence level" BUILDING "$(ev .reputation.level)"
eq "evidence on time counter" 2 "$(ev .reputation.onTimeCount)"
eq "evidence keeps the two events of this loan only" 2 "$(ev '.events | length')"
eq "evidence expectation" on-time "$(ev .expectation)"
eq "evidence duplicates" 0 "$(ev .duplicatePairs)"
holds "evidence records the wait" jq -e '.waitedSeconds | type == "number"' "$EV"
holds "evidence has no token, node host or key" bash -c "! grep -q -e TOKENCANARY -e example.invalid -e CANARYKEY '$EV'"
ok_not_has "$TOKEN_CANARY"
ok_not_has "CANARYKEY"
ok_not_has "rpc.example.invalid"
holds "the token reached curl through stdin" grep -q "$TOKEN_CANARY" "$ST/last-config"
VR
exit_is "the run passes without an expectation flag" 0

# The mirror lags: the first answers say ACTIVE, the third says REPAID. The wait is reported.
mkdir -p "$ST/api/loans_7.queue"
jq '.status = "ACTIVE"' "$ST/api/loans_7.json" >"$ST/api/loans_7.queue/1"
jq '.status = "ACTIVE"' "$ST/api/loans_7.json" >"$ST/api/loans_7.queue/2"
cp "$ST/api/loans_7.json" "$ST/api/loans_7.queue/3"
VERIFY_POLL_INTERVAL=0.6 VR --expect-on-time --wait 20
exit_is "the verifier waits for the mirror" 0
holds "the wait before the match is reported" jq -e '.waitedSeconds >= 1' "$EV"
rm -rf "$ST/api/loans_7.queue"

# The API never matches.
set_api_loan 7 ACTIVE 100027397 100027397 2
VR
exit_is "an API that never matches exits 4" 4
ok_has "did not mirror the chain"
on_time_state
STUB_API_DOWN=1 VR
exit_is "an unreachable API exits 3" 3
echo 401 >"$ST/api/loans_7.code"
VR
exit_is "a refused token exits 3" 3
ok_has "api-login.sh again"
rm -f "$ST/api/loans_7.code"
echo 404 >"$ST/api/loans_7.code"
VR
exit_is "a loan the API does not know yet exits 4" 4
rm -f "$ST/api/loans_7.code"

# Amount, installment and duplicate mismatches.
on_time_state
set_api_loan 7 REPAID 100027397 50013698 2
VR
exit_is "an amountRepaid mismatch exits 1" 1
ok_has "amountRepaid differs"
on_time_state
set_api_loan 7 REPAID 100000000 100027397 2
VR
exit_is "a totalDue mismatch exits 1" 1
ok_has "totalDue differs"
on_time_state
set_api_loan 7 REPAID 100027397 100027397 1
VR
exit_is "installmentsPaid below the installment count of a repaid loan exits 1" 1
on_time_state
set_history "$profile" "$(event 2 7 REPAID_ON_TIME 20 570 "" "$TX1" 3)" "$(event 3 7 REPAID_ON_TIME 20 590 "" "$TX1" 3)"
VR
exit_is "a duplicated txHash and logIndex pair exits 1" 1
ok_has "duplicated"
on_time_state
set_history "$profile" "$(event 2 7 REPAID_ON_TIME 20 570 "" "$TX1" 3)" "$(event 3 7 REPAID_ON_TIME 20 590 "" "$TX1" 4)"
VR --expect-on-time
exit_is "the same txHash with another logIndex is not a duplicate" 0
on_time_state
set_history "$profile" "$(event 2 7 REPAID_ON_TIME 20 570 "" "$TX1" 3)"
VR
exit_is "fewer history entries than installmentsPaid exits 1" 1
ok_has "installmentsPaid is 2"
on_time_state
set_history "$profile" "$(event 2 7 REPAID_ON_TIME 20 570 "" "$TX1" 3)" "$(event 3 7 REPAID_ON_TIME 20 590 "" "$TX2" 1)" "$(event 4 9 REPAID_ON_TIME 20 610 "" "$TX3" 0)"
VR --expect-on-time
exit_is "an entry of another loan is not counted" 0
on_time_state
set_history "$profile" "$(event 2 7 REPAID_ON_TIME 20 570 "" "$TX1" 3)" "$(event 3 7 REPAID_LATE -5 565 1 "$TX2" 1)"
VR --expect-on-time
exit_is "a late entry fails the on time expectation" 1
VR
exit_is "the same state passes without the expectation" 0
on_time_state
set_history "$profile" "$(event 2 7 REPAID_ON_TIME 20 570 "" "$TX1" 3)" "$(event 3 7 REPAID_ON_TIME 15 585 "" "$TX2" 1)"
VR --expect-on-time
exit_is "a wrong on time delta fails the expectation" 1

# Chain facts.
on_time_state
set_chain "0x1111111111111111111111111111111111111111" 2 3 100027397 100027397
VR
exit_is "a loan of another borrower exits 1" 1
set_chain "$BORROWER" 2 0 0 0
VR
exit_is "a loan with no status on chain exits 1" 1
STUB_NETWORK=999 VR
exit_is "a wrong chain id exits 2" 2
ok_not_has "CANARYKEY"
STUB_RPC_DOWN=1 VR
exit_is "an unreachable RPC exits 3" 3
ok_not_has "CANARYKEY"
STUB_CALL_FAIL=1 VR
exit_is "a failing chain read exits 3" 3
ok_not_has "CANARYKEY"
ok_not_has "example.invalid/v2"

# Run B: one installment paid one day late.
late_state() { # daysLate, delta
  set_chain "$BORROWER" 1 3 100013699 100013699
  set_api_loan 8 REPAID 100013699 100013699 1
  set_reputation 545 BUILDING 0 1
  set_history "$profile" "$(event 2 8 REPAID_LATE "$2" 545 "$1" "$TX3" 0)"
}
VRB() {
  rm -f "$EV"
  run bash "$VERIFY" --api-base "$API" --token-file "$WORK/token" --book "$BOOK" --loan-id 8 \
    --borrower "$BORROWER" --wait 1 --evidence "$EV" "$@"
}
late_state 1 -5
VRB --expect-late 1
exit_is "one day late with delta minus 5 passes" 0
eq "evidence expectation for a late run" late-1 "$(ev .expectation)"
eq "evidence late event type" REPAID_LATE "$(ev '.events[0].type')"
eq "evidence late event delta" -5 "$(ev '.events[0].delta')"
eq "evidence late event days" 1 "$(ev '.events[0].daysLate')"
VRB --expect-late 2
exit_is "a wrong days late fails" 1
ok_has "daysLate"
late_state 1 -10
VRB --expect-late 1
exit_is "a wrong late delta fails" 1
ok_has "delta"
late_state 21 -100
VRB --expect-late 21
exit_is "the penalty is capped at minus 100" 0
late_state 21 -105
VRB --expect-late 21
exit_is "a penalty above the cap fails" 1
set_chain "$BORROWER" 1 3 100013699 100013699
set_history "$profile" "$(event 2 8 REPAID_ON_TIME 20 570 "" "$TX3" 0)"
VRB --expect-late 1
exit_is "a missing late entry fails" 1
ok_has "exactly one REPAID_LATE"
late_state 1 -5
VRB --expect-on-time
exit_is "a late run fails the on time expectation" 1

# Usage.
late_state 1 -5
VRB --expect-late 1 --expect-on-time
exit_is "the two expectation flags exclude each other" 2
VRB --expect-late 0
exit_is "zero days late is refused" 2
VRB --expect-late abc
exit_is "a non numeric days late is refused" 2
run bash "$VERIFY" --api-base "$API" --token-file "$WORK/token" --book nope --loan-id 8 --borrower "$BORROWER"
exit_is "a bad book address is refused" 2
run bash "$VERIFY" --api-base "$API" --token-file "$WORK/token" --book "$BOOK" --loan-id x --borrower "$BORROWER"
exit_is "a bad loan id is refused" 2
run bash "$VERIFY" --api-base http://api.example.invalid/api/v1 --token-file "$WORK/token" --book "$BOOK" --loan-id 8 --borrower "$BORROWER"
exit_is "an http API base is refused" 2
cp "$WORK/token" "$WORK/token-open"
chmod 644 "$WORK/token-open"
run bash "$VERIFY" --api-base "$API" --token-file "$WORK/token-open" --book "$BOOK" --loan-id 8 --borrower "$BORROWER"
exit_is "a token file readable by others is refused" 2
run bash "$VERIFY" --api-base "$API" --token-file "$WORK/missing" --book "$BOOK" --loan-id 8 --borrower "$BORROWER"
exit_is "a missing token file is refused" 2
run bash "$VERIFY" --api-base "$API" --token-file "$WORK/token" --book "$BOOK" --loan-id 8 --borrower "$BORROWER" --bogus
exit_is "an unknown flag is refused" 2
holds "verify-run keeps the token off the command line" no_code_match '(-H|--header)[[:space:]]+["'"'"']?Authorization' "$VERIFY"
holds "verify-run never prints the token" no_code_match 'echo.*\$\{?token([^A-Za-z_]|$)' "$VERIFY"

# ---------------------------------------------------------------- 3. rpc-fault-proxy.py

cat >"$WORK/upstream.py" <<'PY'
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

port_file, log_file = sys.argv[1], sys.argv[2]


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        with open(log_file, "a") as f:
            f.write(self.path + " " + body.decode() + "\n")
        req = json.loads(body)
        if isinstance(req, list):
            out = [{"jsonrpc": "2.0", "id": r.get("id"), "result": "0x1"} for r in req]
        else:
            out = {"jsonrpc": "2.0", "id": req.get("id"), "result": "0x1"}
        data = json.dumps(out).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


srv = HTTPServer(("127.0.0.1", 0), H)
open(port_file, "w").write(str(srv.server_address[1]))
srv.serve_forever()
PY

cat >"$WORK/req.py" <<'PY'
import http.client, sys, urllib.parse

# req.py METHOD URL [BODY | --claim-length N] : prints STATUS, Retry-After and the body.
method, url = sys.argv[1], urllib.parse.urlsplit(sys.argv[2])
conn = http.client.HTTPConnection(url.hostname, url.port, timeout=10)
headers = {"Content-Type": "application/json"}
if len(sys.argv) > 4 and sys.argv[3] == "--claim-length":
    conn.putrequest(method, url.path)
    conn.putheader("Content-Length", sys.argv[4])
    conn.endheaders()
else:
    body = sys.argv[3].encode() if len(sys.argv) > 3 else None
    conn.request(method, url.path, body=body, headers=headers)
r = conn.getresponse()
print(r.status)
print(r.getheader("Retry-After") or "-")
print(r.read().decode())
PY

rq() { # METHOD URL [BODY]
  python3 -I "$WORK/req.py" "$@"
}

UP_PORT_FILE="$WORK/upstream.port"
UP_LOG="$WORK/upstream.log"
: >"$UP_LOG"
python3 -I "$WORK/upstream.py" "$UP_PORT_FILE" "$UP_LOG" &
UP_PID=$!
PIDS="$PIDS $UP_PID"
for _ in $(seq 1 50); do [ -s "$UP_PORT_FILE" ] && break; sleep 0.1; done
[ -s "$UP_PORT_FILE" ] || fail "the stub upstream did not start"
UP_PORT="$(cat "$UP_PORT_FILE")"
UP_URL="http://127.0.0.1:$UP_PORT/v2/CANARYKEYCANARYKEY0123456789"

# start_proxy LOGFILE ARGS... : starts the proxy on an ephemeral loopback port, prints the port.
start_proxy() {
  local log="$1"
  shift
  : >"$log"
  UPSTREAM_CANARY_URL="$UP_URL" python3 -I "$PROXY" --upstream-env UPSTREAM_CANARY_URL --listen 127.0.0.1:0 "$@" >"$log" 2>&1 &
  echo $! >"$log.pid"
  local port=""
  for _ in $(seq 1 50); do
    port="$(sed -n 's/.*listening on 127.0.0.1:\([0-9]*\).*/\1/p' "$log" | head -n 1)"
    [ -z "$port" ] || break
    sleep 0.1
  done
  [ -n "$port" ] || fail "the proxy did not start: $(cat "$log")"
  printf '%s' "$port"
}

PLOG="$WORK/proxy.log"
PP="$(start_proxy "$PLOG")"
P="http://127.0.0.1:$PP"
REQ1='{"jsonrpc":"2.0","id":42,"method":"eth_blockNumber","params":[]}'

OUT="$(rq POST "$P/" "$REQ1")"
eq "a normal request is forwarded with the upstream status" 200 "$(printf '%s\n' "$OUT" | sed -n 1p)"
ok_has '"result": "0x1"'
holds "the upstream answer keeps the request id" bash -c "printf '%s' '$OUT' | grep -q '\"id\": 42'"
holds "the upstream got the full path and the body" grep -q "^/v2/CANARYKEYCANARYKEY0123456789 .*eth_blockNumber" "$UP_LOG"
HITS="$(wc -l <"$UP_LOG" | tr -d ' ')"
OUT="$(rq GET "$P/__fault/status")"
ok_has '"limited": false'

OUT="$(rq POST "$P/__fault/on")"
ok_has '"limited": true'
OUT="$(rq POST "$P/" "$REQ1")"
eq "the limit mode answers 429" 429 "$(printf '%s\n' "$OUT" | sed -n 1p)"
eq "the limit answer carries Retry-After 5" 5 "$(printf '%s\n' "$OUT" | sed -n 2p)"
ok_has '"code": -32005'
ok_has 'rate limit exceeded'
holds "the limit answer echoes the request id" bash -c "printf '%s' '$OUT' | grep -q '\"id\": 42'"
eq "nothing reached the upstream while limited" "$HITS" "$(wc -l <"$UP_LOG" | tr -d ' ')"
OUT="$(rq POST "$P/any/path" '[{"jsonrpc":"2.0","id":1,"method":"eth_call"},{"jsonrpc":"2.0","id":2,"method":"eth_getBalance"}]')"
eq "a batch is limited too" 429 "$(printf '%s\n' "$OUT" | sed -n 1p)"
holds "a batch answer holds one error per request" bash -c "printf '%s' '$OUT' | sed 1,2d | jq -e 'length == 2 and .[0].id == 1 and .[1].id == 2 and .[0].error.code == -32005' >/dev/null"
OUT="$(rq GET "$P/__fault/status")"
ok_has '"manual": true'

OUT="$(rq POST "$P/__fault/off")"
ok_has '"limited": false'
OUT="$(rq POST "$P/" "$REQ1")"
eq "the proxy recovers after the limit is off" 200 "$(printf '%s\n' "$OUT" | sed -n 1p)"
ok_has '"result": "0x1"'

OUT="$(rq POST "$P/" --claim-length 1048577)"
eq "a body above 1 MB is refused with 413" 413 "$(printf '%s\n' "$OUT" | sed -n 1p)"

# Every log line has the same shape and holds no secret.
LOG_BAD="$(sed 1d "$PLOG" | grep -Evc '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z [A-Za-z0-9_]+ (forward|limited|control|on|off|refused) [0-9]{3}$' || true)"
eq "every proxy log line is time, method, decision and status" 0 "$LOG_BAD"
holds "the log records the forwarded method" grep -q ' eth_blockNumber forward 200$' "$PLOG"
holds "the log records the limited decision" grep -q ' eth_blockNumber limited 429$' "$PLOG"
holds "the log records the batch" grep -q ' batch limited 429$' "$PLOG"
OUT="$(cat "$PLOG")"
ok_not_has "CANARYKEY"
ok_not_has "/v2/"
ok_not_has "$UP_PORT"
ok_not_has "$UP_URL"

# A scheduled window: forward, then limited, then recovered, without any control call.
SLOG="$WORK/proxy-schedule.log"
SP="$(start_proxy "$SLOG" --limit-after 1 --limit-for 1.5)"
S="http://127.0.0.1:$SP"
OUT="$(rq POST "$S/" "$REQ1")"
eq "before the window the proxy forwards" 200 "$(printf '%s\n' "$OUT" | sed -n 1p)"
sleep 1.3
OUT="$(rq POST "$S/" "$REQ1")"
eq "inside the window the proxy answers 429" 429 "$(printf '%s\n' "$OUT" | sed -n 1p)"
sleep 1.7
OUT="$(rq POST "$S/" "$REQ1")"
eq "after the window the proxy forwards again" 200 "$(printf '%s\n' "$OUT" | sed -n 1p)"
OUT="$(cat "$SLOG")"
ok_not_has "CANARYKEY"

# Usage and safety.
run_bounded env UPSTREAM_CANARY_URL="$UP_URL" python3 -I "$PROXY" --upstream-env UPSTREAM_CANARY_URL --listen 0.0.0.0:0
exit_is "a wildcard listen address is refused" 2
ok_has "non loopback"
run_bounded env UPSTREAM_CANARY_URL="$UP_URL" python3 -I "$PROXY" --upstream-env UPSTREAM_CANARY_URL --listen 192.168.1.5:8545
exit_is "a LAN listen address is refused" 2
run_bounded env UPSTREAM_CANARY_URL="$UP_URL" python3 -I "$PROXY" --upstream-env UPSTREAM_CANARY_URL --listen example.com:8545
exit_is "a host name that is not loopback is refused" 2
run_bounded env -u NOPE_NOT_SET python3 -I "$PROXY" --upstream-env NOPE_NOT_SET --listen 127.0.0.1:0
exit_is "a missing upstream variable is refused" 2
run_bounded env UPSTREAM_CANARY_URL="http://rpc.example.invalid/v2/CANARYKEYCANARYKEY0123456789" python3 -I "$PROXY" --upstream-env UPSTREAM_CANARY_URL --listen 127.0.0.1:0
exit_is "a plain http upstream that is not loopback is refused" 2
ok_not_has "CANARYKEY"
run_bounded env UPSTREAM_CANARY_URL="$UP_URL" python3 -I "$PROXY" --upstream-env UPSTREAM_CANARY_URL --listen 127.0.0.1:0 --limit-after 3
exit_is "the window flags go together" 2
run python3 -I "$PROXY" --help
exit_is "help works" 0
holds "the proxy takes the upstream from the environment, not from a flag" no_code_match 'add_argument\("--upstream"' "$PROXY"

# The upstream goes away: the proxy answers 502 and still leaks nothing.
kill "$UP_PID" 2>/dev/null || true
wait "$UP_PID" 2>/dev/null || true
OUT="$(rq POST "$P/" "$REQ1")"
eq "an unreachable upstream answers 502" 502 "$(printf '%s\n' "$OUT" | sed -n 1p)"
ok_not_has "CANARYKEY"
ok_not_has "$UP_PORT"

echo "demo-test: ok $CASES cases"
