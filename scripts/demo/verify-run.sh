#!/usr/bin/env bash
# Compares the loan and reputation state the deployed API serves with the chain, after a demo run.
#
#   bash scripts/demo/verify-run.sh --api-base https://HOST/api/v1 --token-file ~/.latifi/api-token \
#     --book 0xLOANBOOK --loan-id 7 --borrower 0xBORROWER --expect-on-time
#
# Required:
#   --api-base URL       API base including /api/v1 (https, or http for localhost)
#   --token-file FILE    access token written by scripts/demo/api-login.sh (mode 600)
#   --book ADDR          LoanBook address
#   --loan-id N          loan to check
#   --borrower ADDR      borrower whose reputation history is read
# Optional:
#   --wait SECONDS       how long the API may take to mirror the chain status [60]
#   --expect-on-time     every repayment of this loan is REPAID_ON_TIME with delta +20
#   --expect-late DAYS   exactly one REPAID_LATE entry of this loan, with daysLate DAYS and
#                        delta -min(5 * DAYS, 100) (policy of latifi-api/docs/reputation-ddd.md)
#   --evidence FILE      [broadcast/verify-run-LOANID-UTCSTAMP.json] public data only
#
# Checks, in order: the loan status on chain and in the API (polled every 2 seconds until they
# match, the wait is reported), totalDue and amountRepaid against the chain, installmentsPaid
# against the repayments in the history, no two history entries with the same txHash and
# logIndex, and the optional expectations. Prints a short summary and `verify-run: ok loan N`.
#
# Exit codes: 0 everything matched, 1 a comparison or expectation failed, 2 bad usage or a chain
# other than 80002, 3 the RPC or the API is unreachable (or the token is refused), 4 the API did
# not mirror the chain within the wait. The RPC URL reaches cast only through ETH_RPC_URL and is
# never printed or written. The token travels to curl through stdin, not through the command line.
# Needs cast, curl and jq. Compatible with bash 3.2.
set -euo pipefail

# shellcheck source=../gate/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../gate/lib.sh"

api_base=""
token_file=""
book=""
loan_id=""
borrower=""
wait_s=60
expect_on_time=0
expect_late=""
evidence=""
poll_interval="${VERIFY_POLL_INTERVAL:-2}"

is_uint() {
  case "$1" in '' | *[!0-9]*) return 1 ;; esac
  return 0
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --expect-on-time)
      expect_on_time=1
      shift
      ;;
    --api-base | --token-file | --book | --loan-id | --borrower | --wait | --expect-late | --evidence)
      need_value "$1" "$#" "${2:-}"
      case "$1" in
        --api-base) api_base="$2" ;;
        --token-file) token_file="$2" ;;
        --book) book="$2" ;;
        --loan-id) loan_id="$2" ;;
        --borrower) borrower="$2" ;;
        --wait) wait_s="$2" ;;
        --expect-late) expect_late="$2" ;;
        --evidence) evidence="$2" ;;
      esac
      shift 2
      ;;
    -h | --help)
      sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) die 2 "unknown argument '$1'" ;;
  esac
done

[ -n "$api_base" ] || die 2 "--api-base is required"
[ -n "$token_file" ] || die 2 "--token-file is required"
[ -n "$book" ] || die 2 "--book is required"
[ -n "$loan_id" ] || die 2 "--loan-id is required"
[ -n "$borrower" ] || die 2 "--borrower is required"
is_address "$book" || die 2 "--book is not an address"
is_address "$borrower" || die 2 "--borrower is not an address"
is_uint "$loan_id" || die 2 "--loan-id must be a whole number"
is_uint "$wait_s" || die 2 "--wait must be a whole number of seconds"
if [ -n "$expect_late" ]; then
  is_uint "$expect_late" || die 2 "--expect-late needs a whole number of days"
  [ "$expect_late" -ge 1 ] || die 2 "--expect-late needs at least 1 day"
  [ "$expect_on_time" -eq 0 ] || die 2 "--expect-on-time and --expect-late exclude each other"
fi
for tool in cast curl jq; do
  command -v "$tool" >/dev/null 2>&1 || die 2 "$tool is not installed"
done

api_base="${api_base%/}"
case "$api_base" in
  https://*) ;;
  http://localhost | http://localhost/* | http://localhost:* | http://127.0.0.1 | http://127.0.0.1/* | http://127.0.0.1:*) ;;
  *) die 2 "the API base must be https (http is allowed for localhost only)" ;;
esac

[ -f "$token_file" ] || die 2 "token file not found: $token_file (run scripts/demo/api-login.sh)"
mode="$(stat -c '%a' "$token_file" 2>/dev/null || stat -f '%Lp' "$token_file" 2>/dev/null || echo unknown)"
[ "$mode" = "600" ] || die 2 "the token file must have mode 600, it has $mode"
token="$(tr -d '\r\n' <"$token_file")"
[ -n "$token" ] || die 2 "the token file is empty"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
chmod 700 "$work"

# api_get PATH OUTFILE : prints the HTTP status, 000 when the API cannot be reached. The bearer
# header is handed to curl on stdin as a config line, so the token never shows in a process list.
api_get() {
  local code
  code="$(printf 'header = "Authorization: Bearer %s"\n' "$token" |
    curl -sS --max-time 20 -o "$2" -w '%{http_code}' -K - -H 'Accept: application/json' "$api_base$1" 2>/dev/null || true)"
  case "$code" in [0-9][0-9][0-9]) printf '%s' "$code" ;; *) printf '000' ;; esac
}

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# ---------------------------------------------------------------- chain

require_amoy_strict

GETLOAN_SIG="getLoan(uint256)((address,uint16,uint32,uint8,uint8,address,uint64,uint128,uint128,uint128))"
chain_out="$(cast call "$book" "$GETLOAN_SIG" "$loan_id" 2>/dev/null)" || die 3 "could not read loan $loan_id from the chain"
tuple_field() { printf '%s\n' "$chain_out" | tr -d '()' | awk -F', ' -v n="$1" 'NR == 1 { split($n, a, " "); print a[1] }'; }
chain_borrower="$(tuple_field 1)"
chain_installments="$(tuple_field 4)"
chain_status_code="$(tuple_field 5)"
chain_total_due="$(tuple_field 9)"
chain_total_paid="$(tuple_field 10)"
is_uint "$chain_status_code" || die 3 "the chain answer for loan $loan_id could not be read"
is_uint "$chain_total_due" && is_uint "$chain_total_paid" || die 3 "the chain answer for loan $loan_id has no amounts"
case "$chain_status_code" in
  1) chain_status="OPEN" ;;
  2) chain_status="ACTIVE" ;;
  3) chain_status="REPAID" ;;
  4) chain_status="DEFAULTED" ;;
  *) die 1 "loan $loan_id has no live status on chain (code $chain_status_code): it does not exist or is not requested" ;;
esac
[ "$(lower "$chain_borrower")" = "$(lower "$borrower")" ] || die 1 "loan $loan_id on chain belongs to another borrower than --borrower"

# ---------------------------------------------------------------- API mirror wait

fail() {
  echo "verify-run: FAIL $*" >&2
  exit 1
}

start="$SECONDS"
api_status=""
http=""
while :; do
  http="$(api_get "/loans/$loan_id" "$work/loan.json")"
  case "$http" in
    200)
      api_status="$(jq -r '.status // empty' "$work/loan.json" 2>/dev/null || true)"
      [ "$api_status" != "$chain_status" ] || break
      ;;
    401 | 403) die 3 "the API refused the token (HTTP $http). Run scripts/demo/api-login.sh again" ;;
  esac
  if [ $((SECONDS - start)) -ge "$wait_s" ]; then
    if [ "$http" = "000" ]; then die 3 "the API is unreachable"; fi
    echo "verify-run: the API did not mirror the chain within ${wait_s}s (chain $chain_status, API '${api_status:-none}', last HTTP $http)" >&2
    exit 4
  fi
  sleep "$poll_interval"
done
waited=$((SECONDS - start))

# ---------------------------------------------------------------- loan comparison

api_total_due="$(jq -r '.totalDue // empty' "$work/loan.json")"
api_repaid="$(jq -r '.amountRepaid // empty' "$work/loan.json")"
api_paid_n="$(jq -r '.installmentsPaid // empty' "$work/loan.json")"
is_uint "$api_paid_n" || fail "the API loan has no installmentsPaid"
[ "$api_total_due" = "$chain_total_due" ] || fail "totalDue differs: chain $chain_total_due, API $api_total_due"
[ "$api_repaid" = "$chain_total_paid" ] || fail "amountRepaid differs: chain totalPaid $chain_total_paid, API $api_repaid"
if [ "$chain_status" = "REPAID" ]; then
  [ "$api_paid_n" = "$chain_installments" ] || fail "installmentsPaid is $api_paid_n, the loan has $chain_installments installments and is Repaid"
fi

# ---------------------------------------------------------------- reputation and history

http="$(api_get "/reputation/$borrower" "$work/reputation.json")"
[ "$http" = "200" ] || {
  if [ "$http" = "000" ]; then die 3 "the API is unreachable"; fi
  fail "GET /reputation/{address} answered HTTP $http"
}

echo '[]' >"$work/items.json"
page=0
total=0
while :; do
  http="$(api_get "/reputation/$borrower/history?size=100&page=$page" "$work/page.json")"
  [ "$http" = "200" ] || {
    if [ "$http" = "000" ]; then die 3 "the API is unreachable"; fi
    fail "GET /reputation/{address}/history answered HTTP $http"
  }
  total="$(jq -r '.totalItems // 0' "$work/page.json")"
  jq -s '.[0] + (.[1].items // [])' "$work/items.json" "$work/page.json" >"$work/merged.json"
  mv "$work/merged.json" "$work/items.json"
  page=$((page + 1))
  have="$(jq 'length' "$work/items.json")"
  { [ "$have" -lt "$total" ] && [ "$page" -lt 20 ]; } || break
done

dups="$(jq '[.[] | select(.txHash != null) | "\(.txHash | ascii_downcase)#\(.logIndex)"] | (length - (unique | length))' "$work/items.json")"
[ "$dups" = "0" ] || fail "the history holds $dups duplicated txHash and logIndex pairs"

jq --arg id "$loan_id" '[.[] | select(.loanId == $id and (.type == "REPAID_ON_TIME" or .type == "REPAID_LATE"))]' "$work/items.json" >"$work/loan-events.json"
repay_n="$(jq 'length' "$work/loan-events.json")"
[ "$repay_n" = "$api_paid_n" ] || fail "the history has $repay_n repayment entries for loan $loan_id, installmentsPaid is $api_paid_n"

if [ "$expect_on_time" -eq 1 ]; then
  [ "$repay_n" -ge 1 ] || fail "expected on time repayments for loan $loan_id, found none"
  bad="$(jq '[.[] | select(.type != "REPAID_ON_TIME" or .delta != 20)] | length' "$work/loan-events.json")"
  [ "$bad" = "0" ] || fail "$bad repayment entries of loan $loan_id are not REPAID_ON_TIME with delta 20"
fi

if [ -n "$expect_late" ]; then
  late_penalty=$((expect_late * 5))
  [ "$late_penalty" -le 100 ] || late_penalty=100
  late_n="$(jq '[.[] | select(.type == "REPAID_LATE")] | length' "$work/loan-events.json")"
  [ "$late_n" = "1" ] || fail "expected exactly one REPAID_LATE entry for loan $loan_id, found $late_n"
  late_days="$(jq -r '[.[] | select(.type == "REPAID_LATE")][0].daysLate // empty' "$work/loan-events.json")"
  late_delta="$(jq -r '[.[] | select(.type == "REPAID_LATE")][0].delta // empty' "$work/loan-events.json")"
  [ "$late_days" = "$expect_late" ] || fail "the late entry has daysLate '$late_days', expected $expect_late"
  [ "$late_delta" = "-$late_penalty" ] || fail "the late entry has delta '$late_delta', expected -$late_penalty"
fi

# ---------------------------------------------------------------- evidence and summary

[ -n "$evidence" ] || evidence="$GATE_REPO_ROOT/broadcast/verify-run-$loan_id-$(date -u +%Y%m%dT%H%M%SZ).json"
doc="$(jq -n \
  --arg loan "$loan_id" --arg chainStatus "$chain_status" --arg apiStatus "$api_status" \
  --arg totalDue "$chain_total_due" --arg totalPaid "$chain_total_paid" \
  --argjson paid "$api_paid_n" --argjson waited "$waited" --argjson dups "$dups" \
  --arg expectation "$([ "$expect_on_time" -eq 1 ] && echo on-time || { [ -n "$expect_late" ] && echo "late-$expect_late" || echo none; })" \
  --slurpfile rep "$work/reputation.json" --slurpfile events "$work/loan-events.json" \
  '{loanId: $loan, chainStatus: $chainStatus, apiStatus: $apiStatus, totalDue: $totalDue,
    totalPaid: $totalPaid, installmentsPaid: $paid, waitedSeconds: $waited,
    duplicatePairs: $dups, expectation: $expectation,
    reputation: {score: $rep[0].score, level: $rep[0].level, onTimeCount: $rep[0].onTimeCount,
                 lateCount: $rep[0].lateCount, defaultCount: $rep[0].defaultCount},
    events: ($events[0] | map({type, delta, scoreAfter, daysLate, txHash}))}')"
write_evidence "$evidence" "$doc"

echo "loan $loan_id: chain $chain_status, API $api_status, mirror matched after ${waited}s"
echo "amounts: totalDue $chain_total_due, paid $chain_total_paid, installments paid $api_paid_n"
echo "reputation: score $(jq -r '.score' "$work/reputation.json") level $(jq -r '.level' "$work/reputation.json")" \
  "(on time $(jq -r '.onTimeCount' "$work/reputation.json"), late $(jq -r '.lateCount' "$work/reputation.json")," \
  "defaults $(jq -r '.defaultCount' "$work/reputation.json"))"
jq -r '.[] | "  \(.type) delta \(.delta) score \(.scoreAfter) daysLate \(.daysLate // "-")"' "$work/loan-events.json"
echo "history entries checked: $(jq 'length' "$work/items.json"), duplicates: 0"
echo "evidence: $evidence"
echo "verify-run: ok loan $loan_id"
