#!/usr/bin/env bash
# cycle.sh: runs one full loan cycle (request, fund, repay every installment) between two wallets
# through cast and writes public evidence of it.
#
# Usage:
#   cycle.sh --rpc-url URL (--deployments FILE | --token ADDR --book ADDR) \
#     (--lender-account NAME | --lender-keystore PATH --lender-password-file PATH) \
#     (--borrower-account NAME | --borrower-keystore PATH --borrower-password-file PATH) [options]
#   cycle.sh --dry-run ...   prints every command and makes no cast call at all
#
# Options (defaults in brackets):
#   --chain-id N              80002 or 31337 only [80002]
#   --lender-address ADDR     [public demo lender address]
#   --borrower-address ADDR   [public demo borrower address]
#   --principal BASE_UNITS    1 to 1000000000, the public mint cap [100000000]
#   --rate-bps N              [1000]
#   --term-days N             [1]
#   --installments N          [2]
#   --gas-flags "FLAGS"       gas price flags handed to every send [Amoy: --gas-price 35gwei
#                             --priority-gas-price 30gwei, local chain: none]
#   --evidence FILE           [broadcast/cycle-evidence-CHAINID.json]
#   --min-pol DECIMAL         POL both wallets must hold before anything is sent [0.05]
#
# Signing: only a Foundry keystore, by account name (--account) or by file plus password file.
# The script never reads a password, never passes a secret literal and has no raw key option.
# Keystore passwords are asked by cast itself on the terminal.
#
# Exit codes: 0 done, 1 an assertion failed, 2 bad usage or a chain outside the allow-list,
# 3 RPC missing, unreachable or on another chain, 4 a wallet holds less POL than --min-pol.
#
# Works on bash 3.2 and bash 5. Needs cast. Needs jq only with --deployments.

set -eu

DEMO_LENDER="0xA22412ba83539ACFd3385DA78F6214E800E865a3"
DEMO_BORROWER="0xcb9003E7f369AE9b55C18D8cfEC8A32a12ee61F0"
MINT_CAP=1000000000

die() {
  local code="$1"
  shift
  echo "cycle: $*" >&2
  exit "$code"
}

usage() {
  sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//' >&2
}

is_uint() {
  case "$1" in
    '' | *[!0-9]*) return 1 ;;
  esac
  return 0
}

is_address() {
  printf '%s' "$1" | grep -Eq '^0x[0-9a-fA-F]{40}$'
}

lower() {
  printf '%s' "$1" | tr 'A-Z' 'a-z'
}

# Exact integer arithmetic on wei values held as decimal strings (no floating point).
wei_norm() {
  local v="${1#"${1%%[!0]*}"}"
  printf '%s\n' "${v:-0}"
}

# Returns 0 when A >= B. Compares digit length first, then lexicographically.
wei_ge() {
  local a b
  a="$(wei_norm "$1")"
  b="$(wei_norm "$2")"
  if [ "${#a}" -ne "${#b}" ]; then
    [ "${#a}" -gt "${#b}" ]
    return
  fi
  [ "$a" = "$b" ] || [ "$(
    LC_ALL=C
    [[ "$a" > "$b" ]] && echo gt
  )" = "gt" ]
}

# A minus B for A >= B, digit by digit.
wei_sub() {
  local a b i d borrow=0 out=""
  a="$(wei_norm "$1")"
  b="$(wei_norm "$2")"
  while [ "${#b}" -lt "${#a}" ]; do b="0$b"; done
  i=$((${#a} - 1))
  while [ "$i" -ge 0 ]; do
    d=$((${a:$i:1} - ${b:$i:1} - borrow))
    if [ "$d" -lt 0 ]; then
      d=$((d + 10))
      borrow=1
    else
      borrow=0
    fi
    out="$d$out"
    i=$((i - 1))
  done
  wei_norm "$out"
}

# Decimal POL amount such as 0.05 or 1 to wei. Returns 1 on a malformed amount.
pol_to_wei() {
  local v="$1" int frac
  case "$v" in
    '' | *[!0-9.]* | .* | *. | *.*.*) return 1 ;;
  esac
  int="${v%%.*}"
  if [ "$int" = "$v" ]; then frac=""; else frac="${v#*.}"; fi
  [ "${#frac}" -le 18 ] || return 1
  while [ "${#frac}" -lt 18 ]; do frac="${frac}0"; done
  wei_norm "${int}${frac}"
}

# Wei to a POL string without trailing zeros.
wei_to_pol() {
  local w
  w="$(wei_norm "$1")"
  while [ "${#w}" -le 18 ]; do w="0$w"; done
  local int="${w:0:$((${#w} - 18))}" frac="${w:$((${#w} - 18))}"
  frac="${frac%"${frac##*[!0]}"}"
  printf '%s.%s\n' "$int" "${frac:-0}"
}

# Reads a plain tuple such as "(a, b [1e8], c)" from stdin and prints the first token of field N.
tuple_field() {
  tr -d '()' | awk -F', ' -v n="$1" 'NR == 1 { split($n, a, " "); print a[1] }'
}

first_token() {
  awk 'NR == 1 { print $1 }'
}

# ---------------------------------------------------------------- arguments

RPC=""
TOKEN=""
BOOK=""
DEPLOYMENTS=""
CHAIN_ID="80002"
LENDER_ADDR="$DEMO_LENDER"
BORROWER_ADDR="$DEMO_BORROWER"
LENDER_ACCOUNT=""
LENDER_KEYSTORE=""
LENDER_PWFILE=""
BORROWER_ACCOUNT=""
BORROWER_KEYSTORE=""
BORROWER_PWFILE=""
PRINCIPAL="100000000"
RATE_BPS="1000"
TERM_DAYS="1"
INSTALLMENTS="2"
GAS_SET=0
GAS_FLAGS=""
EVIDENCE=""
MIN_POL="0.05"
DRY=0

while [ $# -gt 0 ]; do
  opt="$1"
  case "$opt" in
    --dry-run)
      DRY=1
      shift
      continue
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    --rpc-url | --token | --book | --deployments | --chain-id | --lender-account | --lender-keystore | --lender-password-file | --borrower-account | --borrower-keystore | --borrower-password-file | --lender-address | --borrower-address | --principal | --rate-bps | --term-days | --installments | --gas-flags | --evidence | --min-pol)
      [ $# -ge 2 ] || die 2 "$opt needs a value"
      val="$2"
      shift 2
      ;;
    *)
      usage
      die 2 "unknown option: $opt"
      ;;
  esac
  case "$opt" in
    --rpc-url) RPC="$val" ;;
    --token) TOKEN="$val" ;;
    --book) BOOK="$val" ;;
    --deployments) DEPLOYMENTS="$val" ;;
    --chain-id) CHAIN_ID="$val" ;;
    --lender-account) LENDER_ACCOUNT="$val" ;;
    --lender-keystore) LENDER_KEYSTORE="$val" ;;
    --lender-password-file) LENDER_PWFILE="$val" ;;
    --borrower-account) BORROWER_ACCOUNT="$val" ;;
    --borrower-keystore) BORROWER_KEYSTORE="$val" ;;
    --borrower-password-file) BORROWER_PWFILE="$val" ;;
    --lender-address) LENDER_ADDR="$val" ;;
    --borrower-address) BORROWER_ADDR="$val" ;;
    --principal) PRINCIPAL="$val" ;;
    --rate-bps) RATE_BPS="$val" ;;
    --term-days) TERM_DAYS="$val" ;;
    --installments) INSTALLMENTS="$val" ;;
    --gas-flags)
      GAS_FLAGS="$val"
      GAS_SET=1
      ;;
    --evidence) EVIDENCE="$val" ;;
    --min-pol) MIN_POL="$val" ;;
  esac
done

# Allow-list of chains: the Polygon Amoy testnet and a local chain. Nothing else is accepted.
case "$CHAIN_ID" in
  80002 | 31337) ;;
  *) die 2 "chain id '$CHAIN_ID' is not allowed, use the Polygon Amoy testnet or the local chain" ;;
esac

# Numeric inputs: digits only, short enough for shell arithmetic, no octal surprises.
num() { # NAME VALUE MAXLEN MIN MAX
  is_uint "$2" || die 2 "$1 must be a whole number"
  [ "${#2}" -le "$3" ] || die 2 "$1 is too large"
  local n=$((10#$2))
  [ "$n" -ge "$4" ] && [ "$n" -le "$5" ] || die 2 "$1 must be between $4 and $5"
  printf '%s\n' "$n"
}
PRINCIPAL="$(num --principal "$PRINCIPAL" 10 1 "$MINT_CAP")"
RATE_BPS="$(num --rate-bps "$RATE_BPS" 5 1 5000)"
TERM_DAYS="$(num --term-days "$TERM_DAYS" 4 1 365)"
INSTALLMENTS="$(num --installments "$INSTALLMENTS" 2 1 6)"

MIN_WEI="$(pol_to_wei "$MIN_POL")" || die 2 "--min-pol must be a decimal amount such as 0.05"

is_address "$LENDER_ADDR" || die 2 "--lender-address is not an address"
is_address "$BORROWER_ADDR" || die 2 "--borrower-address is not an address"

# Signing source of each wallet: an account name, or a keystore file plus a password file.
signer() { # ROLE ACCOUNT KEYSTORE PWFILE -> prints the cast flags
  local role="$1" account="$2" keystore="$3" pwfile="$4"
  if [ -n "$account" ] && [ -z "$keystore$pwfile" ]; then
    printf '%s\n' "--account $account"
  elif [ -z "$account" ] && [ -n "$keystore" ] && [ -n "$pwfile" ]; then
    printf '%s\n' "--keystore $keystore --password-file $pwfile"
  else
    die 2 "$role needs --$role-account NAME, or --$role-keystore PATH with --$role-password-file PATH"
  fi
}
signer "lender" "$LENDER_ACCOUNT" "$LENDER_KEYSTORE" "$LENDER_PWFILE" >/dev/null
signer "borrower" "$BORROWER_ACCOUNT" "$BORROWER_KEYSTORE" "$BORROWER_PWFILE" >/dev/null
if [ -n "$LENDER_ACCOUNT" ]; then
  L_SIGN=(--account "$LENDER_ACCOUNT")
  L_SIGN_TEXT="--account $LENDER_ACCOUNT"
else
  L_SIGN=(--keystore "$LENDER_KEYSTORE" --password-file "$LENDER_PWFILE")
  L_SIGN_TEXT="--keystore $LENDER_KEYSTORE --password-file $LENDER_PWFILE"
fi
if [ -n "$BORROWER_ACCOUNT" ]; then
  B_SIGN=(--account "$BORROWER_ACCOUNT")
  B_SIGN_TEXT="--account $BORROWER_ACCOUNT"
else
  B_SIGN=(--keystore "$BORROWER_KEYSTORE" --password-file "$BORROWER_PWFILE")
  B_SIGN_TEXT="--keystore $BORROWER_KEYSTORE --password-file $BORROWER_PWFILE"
fi

# Gas flags: a default per chain, and only gas settings are ever accepted from the caller.
if [ "$GAS_SET" -eq 0 ] && [ "$CHAIN_ID" = "80002" ]; then
  GAS_FLAGS="--gas-price 35gwei --priority-gas-price 30gwei"
fi
gas_ok=1
prev=""
for w in $GAS_FLAGS; do
  case "$prev" in
    --gas-price | --priority-gas-price | --gas-limit)
      printf '%s' "$w" | grep -Eq '^[0-9]+(gwei|wei)?$' || gas_ok=0
      prev=""
      ;;
    "")
      case "$w" in
        --gas-price | --priority-gas-price | --gas-limit) prev="$w" ;;
        *) gas_ok=0 ;;
      esac
      ;;
  esac
done
[ "$gas_ok" -eq 1 ] && [ -z "$prev" ] || die 2 "--gas-flags accepts only --gas-price, --priority-gas-price and --gas-limit with a value"

# Contract addresses.
if [ -n "$DEPLOYMENTS" ]; then
  [ -f "$DEPLOYMENTS" ] || die 2 "deployment record not found: $DEPLOYMENTS"
  command -v jq >/dev/null 2>&1 || die 2 "jq is needed to read --deployments"
  TOKEN="$(jq -r '.contracts.MockStablecoin.address // empty' "$DEPLOYMENTS")"
  BOOK="$(jq -r '.contracts.LoanBook.address // empty' "$DEPLOYMENTS")"
fi
is_address "$TOKEN" || die 2 "the token address is missing or malformed (use --token or --deployments)"
is_address "$BOOK" || die 2 "the book address is missing or malformed (use --book or --deployments)"

if [ "$DRY" -eq 0 ]; then
  [ -n "$RPC" ] || die 2 "--rpc-url is required"
  command -v cast >/dev/null 2>&1 || die 2 "cast is not installed"
fi

[ -n "$EVIDENCE" ] || EVIDENCE="broadcast/cycle-evidence-$CHAIN_ID.json"

# Total due as the contract computes it, used by the dry run only. The live run asks the chain.
LOCAL_TOTAL=$((PRINCIPAL + PRINCIPAL * RATE_BPS * TERM_DAYS / 3650000))

# ---------------------------------------------------------------- dry run

if [ "$DRY" -eq 1 ]; then
  say() { echo "[dry-run] $*"; }
  base=$((LOCAL_TOTAL / INSTALLMENTS))
  interest=$((LOCAL_TOTAL - PRINCIPAL))
  [ "$interest" -ge 1 ] || interest=1
  say "chain $CHAIN_ID, token $TOKEN, book $BOOK"
  say "cast chain-id --rpc-url <rpc-url>"
  say "cast balance $LENDER_ADDR --rpc-url <rpc-url>   (needs at least $MIN_POL POL)"
  say "cast balance $BORROWER_ADDR --rpc-url <rpc-url>   (needs at least $MIN_POL POL)"
  say "cast call $BOOK totalDueFor(uint256,uint256,uint256)(uint256) $PRINCIPAL $RATE_BPS $TERM_DAYS --rpc-url <rpc-url>   (expected $LOCAL_TOTAL)"
  say "cast send $TOKEN mint(uint256) $PRINCIPAL $L_SIGN_TEXT --rpc-url <rpc-url> $GAS_FLAGS --json   (only when the lender holds less)"
  say "cast send $TOKEN approve(address,uint256) $BOOK $PRINCIPAL $L_SIGN_TEXT --rpc-url <rpc-url> $GAS_FLAGS --json"
  say "cast send $TOKEN mint(uint256) $interest $B_SIGN_TEXT --rpc-url <rpc-url> $GAS_FLAGS --json   (only when the borrower holds less)"
  say "cast send $TOKEN approve(address,uint256) $BOOK $LOCAL_TOTAL $B_SIGN_TEXT --rpc-url <rpc-url> $GAS_FLAGS --json"
  say "cast send $BOOK requestLoan(uint256,uint16,uint32,uint8) $PRINCIPAL $RATE_BPS $TERM_DAYS $INSTALLMENTS $B_SIGN_TEXT --rpc-url <rpc-url> $GAS_FLAGS --json"
  say "cast call $BOOK loanCount()(uint256) --rpc-url <rpc-url>   (the new loan id)"
  say "cast send $BOOK fund(uint256) <loan-id> $L_SIGN_TEXT --rpc-url <rpc-url> $GAS_FLAGS --json"
  k=1
  while [ "$k" -le "$INSTALLMENTS" ]; do
    if [ "$k" -eq "$INSTALLMENTS" ]; then
      amt=$((LOCAL_TOTAL - base * (INSTALLMENTS - 1)))
    else
      amt=$base
    fi
    say "cast call $BOOK nextInstallment(uint256)(uint256,uint256,uint256) <loan-id> --rpc-url <rpc-url>   (amountDue expected $amt)"
    say "cast send $BOOK repay(uint256,uint256) <loan-id> <amountDue> $B_SIGN_TEXT --rpc-url <rpc-url> $GAS_FLAGS --json"
    k=$((k + 1))
  done
  say "cast call $BOOK getLoan(uint256) <loan-id> --rpc-url <rpc-url>   (status must be 3)"
  say "cast logs --address $BOOK --from-block <request-block> LoanRepaid(uint256 indexed,uint256,bool) <loan-id> --rpc-url <rpc-url>"
  say "write $EVIDENCE"
  echo "cycle-dry-run-ok"
  exit 0
fi

# ---------------------------------------------------------------- live run

GETLOAN_SIG="getLoan(uint256)((address,uint16,uint32,uint8,uint8,address,uint64,uint128,uint128,uint128))"
REPUTATION_SIG="reputationOf(address)((uint32,uint32,uint32))"
REPAID_SIG="LoanRepaid(uint256 indexed,uint256,bool)"

step() { echo "step: $*"; }
fail() { die 1 "assertion failed: $*"; }

rcall() { # cast call with the RPC attached
  cast call "$@" --rpc-url "$RPC"
}

TXS=""
LAST_HASH=""
LAST_BLOCK=""

# send LABEL ROLE TARGET SIG ARGS... : one signed transaction, with its hash and block recorded.
send() {
  local label="$1" role="$2" target="$3" out hash blk status
  shift 3
  if [ "$role" = "lender" ]; then
    out="$(cast send "$target" "$@" "${L_SIGN[@]}" --rpc-url "$RPC" $GAS_FLAGS --json)" ||
      die 1 "transaction '$label' failed or was rejected"
  else
    out="$(cast send "$target" "$@" "${B_SIGN[@]}" --rpc-url "$RPC" $GAS_FLAGS --json)" ||
      die 1 "transaction '$label' failed or was rejected"
  fi
  hash="$(printf '%s\n' "$out" | sed -n 's/.*"transactionHash"[[:space:]]*:[[:space:]]*"\(0x[0-9a-fA-F]\{64\}\)".*/\1/p' | head -n 1)"
  [ -n "$hash" ] || fail "transaction '$label' returned no transaction hash"
  blk="$(printf '%s\n' "$out" | sed -n 's/.*"blockNumber"[[:space:]]*:[[:space:]]*"\{0,1\}\([0-9a-fA-FxX]*\)"\{0,1\}.*/\1/p' | head -n 1)"
  case "$blk" in
    0x[0-9a-fA-F]* | 0X[0-9a-fA-F]*) blk=$((blk)) ;;
  esac
  is_uint "$blk" || fail "transaction '$label' returned no block number"
  status="$(printf '%s\n' "$out" | sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\{0,1\}\([A-Za-z0-9]*\)"\{0,1\}.*/\1/p' | head -n 1)"
  case "$status" in
    '' | 0x1 | 1 | success) ;;
    *) fail "transaction '$label' ($hash) did not succeed, status $status" ;;
  esac
  LAST_HASH="$hash"
  LAST_BLOCK="$blk"
  TXS="${TXS}${TXS:+,}{\"name\":\"$label\",\"hash\":\"$hash\",\"block\":$blk}"
  step "$label tx $hash block $blk"
}

token_balance() { # ADDRESS
  rcall "$TOKEN" "balanceOf(address)(uint256)" "$1" | first_token
}

loan_field() { # ID FIELD
  rcall "$BOOK" "$GETLOAN_SIG" "$1" | tuple_field "$2"
}

rep_field() { # ADDRESS FIELD
  rcall "$BOOK" "$REPUTATION_SIG" "$1" | tuple_field "$2"
}

# Preflight: the chain, then both POL balances, before anything is signed.
step "preflight chain id"
ACTUAL_ID="$(cast chain-id --rpc-url "$RPC" 2>/dev/null | first_token)" ||
  die 3 "could not read the chain id from the RPC endpoint"
[ -n "$ACTUAL_ID" ] || die 3 "the RPC endpoint did not answer the chain id"
[ "$ACTUAL_ID" = "$CHAIN_ID" ] || die 3 "the RPC endpoint reports chain id $ACTUAL_ID, expected $CHAIN_ID"

step "preflight POL balances"
LOW=0
for addr in "$LENDER_ADDR" "$BORROWER_ADDR"; do
  bal="$(cast balance "$addr" --rpc-url "$RPC" 2>/dev/null | first_token)" ||
    die 3 "could not read the POL balance of $addr"
  is_uint "$bal" || die 3 "the RPC endpoint returned a bad balance for $addr"
  if ! wei_ge "$bal" "$MIN_WEI"; then
    echo "cycle: wallet $addr holds $(wei_to_pol "$bal") POL and needs at least $MIN_POL POL, short by $(wei_to_pol "$(wei_sub "$MIN_WEI" "$bal")") POL" >&2
    LOW=1
  fi
done
[ "$LOW" -eq 0 ] || exit 4

TOTAL_DUE="$(rcall "$BOOK" "totalDueFor(uint256,uint256,uint256)(uint256)" "$PRINCIPAL" "$RATE_BPS" "$TERM_DAYS" | first_token)"
is_uint "$TOTAL_DUE" || fail "totalDueFor returned '$TOTAL_DUE'"
[ "$TOTAL_DUE" -gt "$PRINCIPAL" ] || fail "total due $TOTAL_DUE is not above the principal $PRINCIPAL"
INTEREST=$((TOTAL_DUE - PRINCIPAL))
step "principal $PRINCIPAL, total due $TOTAL_DUE, interest $INTEREST"

# Lender: tokens for the principal, then an approval for exactly the principal.
LBAL="$(token_balance "$LENDER_ADDR")"
is_uint "$LBAL" || fail "lender token balance is '$LBAL'"
if [ "$LBAL" -lt "$PRINCIPAL" ]; then
  send "lender-mint" lender "$TOKEN" "mint(uint256)" "$((PRINCIPAL - LBAL))"
fi
send "lender-approve" lender "$TOKEN" "approve(address,uint256)" "$BOOK" "$PRINCIPAL"

# Borrower: tokens for the interest (the principal arrives with the funding), then an approval for
# exactly the total due.
BBAL="$(token_balance "$BORROWER_ADDR")"
is_uint "$BBAL" || fail "borrower token balance is '$BBAL'"
if [ "$BBAL" -lt "$INTEREST" ]; then
  send "borrower-mint" borrower "$TOKEN" "mint(uint256)" "$((INTEREST - BBAL))"
fi
send "borrower-approve" borrower "$TOKEN" "approve(address,uint256)" "$BOOK" "$TOTAL_DUE"

REP_ON_BEFORE="$(rep_field "$BORROWER_ADDR" 1)"
REP_LATE_BEFORE="$(rep_field "$BORROWER_ADDR" 2)"

send "request" borrower "$BOOK" "requestLoan(uint256,uint16,uint32,uint8)" "$PRINCIPAL" "$RATE_BPS" "$TERM_DAYS" "$INSTALLMENTS"
REQUEST_BLOCK="$LAST_BLOCK"
LOAN_ID="$(rcall "$BOOK" "loanCount()(uint256)" | first_token)"
is_uint "$LOAN_ID" || fail "loanCount returned '$LOAN_ID'"
[ "$LOAN_ID" -ge 1 ] || fail "loan id is $LOAN_ID after the request"
[ "$(lower "$(loan_field "$LOAN_ID" 1)")" = "$(lower "$BORROWER_ADDR")" ] ||
  fail "loan $LOAN_ID does not belong to the borrower wallet (another request may have been mined in between)"
[ "$(loan_field "$LOAN_ID" 5)" = "1" ] || fail "loan $LOAN_ID is not Open after the request"
[ "$(loan_field "$LOAN_ID" 8)" = "$PRINCIPAL" ] || fail "loan $LOAN_ID has another principal"
step "loan $LOAN_ID is Open"

BBAL_BEFORE_FUND="$(token_balance "$BORROWER_ADDR")"
send "fund" lender "$BOOK" "fund(uint256)" "$LOAN_ID"
[ "$(loan_field "$LOAN_ID" 5)" = "2" ] || fail "loan $LOAN_ID is not Active after the funding"
[ "$(lower "$(loan_field "$LOAN_ID" 6)")" = "$(lower "$LENDER_ADDR")" ] ||
  fail "loan $LOAN_ID was funded by another wallet than the lender address"
BBAL_AFTER_FUND="$(token_balance "$BORROWER_ADDR")"
[ "$((BBAL_AFTER_FUND - BBAL_BEFORE_FUND))" -eq "$PRINCIPAL" ] ||
  fail "the borrower token balance did not grow by exactly the principal"
step "loan $LOAN_ID is Active, the borrower received $PRINCIPAL"

# Repayments: every amount comes from nextInstallment, never from arithmetic of this script.
PAYMENTS=0
while [ "$PAYMENTS" -le "$INSTALLMENTS" ]; do
  STATUS="$(loan_field "$LOAN_ID" 5)"
  if [ "$STATUS" = "3" ]; then
    break
  fi
  [ "$STATUS" = "2" ] || fail "loan $LOAN_ID has status $STATUS in the middle of the repayments"
  AMOUNT_DUE="$(rcall "$BOOK" "nextInstallment(uint256)(uint256,uint256,uint256)" "$LOAN_ID" | sed -n 3p | first_token)"
  is_uint "$AMOUNT_DUE" || fail "nextInstallment returned '$AMOUNT_DUE'"
  [ "$AMOUNT_DUE" -ge 1 ] || fail "nextInstallment returned an amount of zero"
  PAYMENTS=$((PAYMENTS + 1))
  send "repay-$PAYMENTS" borrower "$BOOK" "repay(uint256,uint256)" "$LOAN_ID" "$AMOUNT_DUE"
done

FINAL_STATUS="$(loan_field "$LOAN_ID" 5)"
[ "$FINAL_STATUS" = "3" ] || fail "loan $LOAN_ID ended with status $FINAL_STATUS, expected 3 (Repaid)"
TOTAL_PAID="$(loan_field "$LOAN_ID" 10)"
[ "$TOTAL_PAID" = "$TOTAL_DUE" ] || fail "totalPaid is $TOTAL_PAID, expected $TOTAL_DUE"
step "loan $LOAN_ID is Repaid after $PAYMENTS payments, totalPaid $TOTAL_PAID"

REP_ON="$(rep_field "$BORROWER_ADDR" 1)"
REP_LATE="$(rep_field "$BORROWER_ADDR" 2)"
REP_DEF="$(rep_field "$BORROWER_ADDR" 3)"
[ "$(( (REP_ON - REP_ON_BEFORE) + (REP_LATE - REP_LATE_BEFORE) ))" -eq "$PAYMENTS" ] ||
  fail "reputation counters moved by another amount than the $PAYMENTS payments made"
step "reputation onTime $REP_ON, late $REP_LATE, defaulted $REP_DEF"

LOGS="$(cast logs --address "$BOOK" --from-block "$REQUEST_BLOCK" "$REPAID_SIG" "$LOAN_ID" --rpc-url "$RPC")" ||
  fail "could not read the LoanRepaid logs"
EVENTS="$(printf '%s\n' "$LOGS" | grep -c '^- address' || true)"
[ "$EVENTS" -eq "$PAYMENTS" ] || fail "found $EVENTS LoanRepaid events, expected $PAYMENTS"
step "$EVENTS LoanRepaid events"

# Evidence: public data only, written with printf.
mkdir -p "$(dirname "$EVIDENCE")"
printf '{"chainId":%s,"token":"%s","book":"%s","loanId":%s,"principal":"%s","totalDue":"%s","installments":%s,"txs":[%s],"finalStatus":%s,"counters":{"onTime":%s,"late":%s,"defaulted":%s},"repaidEvents":%s}\n' \
  "$CHAIN_ID" "$TOKEN" "$BOOK" "$LOAN_ID" "$PRINCIPAL" "$TOTAL_DUE" "$INSTALLMENTS" "$TXS" \
  "$FINAL_STATUS" "$REP_ON" "$REP_LATE" "$REP_DEF" "$EVENTS" >"$EVIDENCE"
step "evidence written to $EVIDENCE"

echo "cycle-ok"
