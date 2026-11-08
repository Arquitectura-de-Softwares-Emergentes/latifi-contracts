#!/usr/bin/env bash
# rehearse-local.sh: rehearses the whole Amoy flow on a private chain, inside the Foundry image.
#
# What it does, in order:
#   1. starts anvil (chain id 31337) inside the container;
#   2. derives four throwaway keystores from the PUBLIC default anvil mnemonic at run time, in a
#      temporary directory with mode 700 and a random password file with mode 600;
#   3. deploys Deploy.s.sol with a keystore, a password file and the same flag names as the live
#      command (--broadcast --slow --priority-gas-price --with-gas-price);
#   4. runs scripts/cycle.sh against anvil, with keystore and password file signing;
#   5. proves a late payment, a default after 8 days with a failed repayment afterwards and the
#      exact grace boundary (7 days after the due time fails, one more second succeeds).
# It prints rehearsal-ok and the two contract addresses when every assertion held.
#
# The keys are the public anvil development keys. They never touch the repo, are never printed and
# must never be used on a public chain. Nothing here talks to Polygon Amoy.
#
# Run it with Docker on your own machine (it re-runs itself in the image when anvil is missing):
#   bash scripts/rehearse-local.sh
# Exit codes: 0 rehearsal-ok, 1 an assertion failed, 2 Docker or a tool is missing.

set -eu

IMAGE="ghcr.io/foundry-rs/foundry:v1.8.7"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! command -v anvil >/dev/null 2>&1; then
  if ! command -v docker >/dev/null 2>&1; then
    echo "rehearse-local: anvil is not installed and Docker is missing. Install Docker (OrbStack works) or Foundry v1.8.7." >&2
    exit 2
  fi
  exec docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp -v "$PWD:/work" -w /work \
    --entrypoint bash "$IMAGE" scripts/rehearse-local.sh
fi

PORT=8545
RPC="http://127.0.0.1:$PORT"
# The public default anvil mnemonic, printed in the anvil documentation. Not a secret.
ANVIL_MNEMONIC="test test test test test test test test test test test junk"

TMP="$(mktemp -d)"
chmod 700 "$TMP"
KS="$TMP/ks"
PW="$TMP/pw"
mkdir -p "$KS"
chmod 700 "$KS"
od -An -N16 -tx1 /dev/urandom | tr -d ' \n' >"$PW"
chmod 600 "$PW"
ANVIL_PID=""
cleanup() {
  [ -z "$ANVIL_PID" ] || kill "$ANVIL_PID" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

fail() {
  echo "rehearse-local: assertion failed: $*" >&2
  exit 1
}
step() { echo "step: $*"; }
first() { awk 'NR == 1 { print $1 }'; }

anvil --silent --port "$PORT" >"$TMP/anvil.log" 2>&1 &
ANVIL_PID=$!
i=0
until [ "$(cast chain-id --rpc-url "$RPC" 2>/dev/null || true)" = "31337" ]; do
  i=$((i + 1))
  [ "$i" -le 60 ] || fail "anvil did not answer on $RPC"
  sleep 0.5
done
step "anvil is up, chain id 31337"

# Keystores. Each derived key lives in one shell variable, goes straight into the import and is
# unset right after. Nothing prints it.
idx=0
for name in deployer lender borrower stranger; do
  k="$(cast wallet private-key "$ANVIL_MNEMONIC" "$idx")"
  cast wallet import "$name" --keystore-dir "$KS" --private-key "$k" --unsafe-password "$(cat "$PW")" >/dev/null
  unset k
  idx=$((idx + 1))
done
addr() { cast wallet address --keystore "$KS/$1" --password-file "$PW"; }
DEPLOYER="$(addr deployer)"
LENDER="$(addr lender)"
BORROWER="$(addr borrower)"
STRANGER="$(addr stranger)"
step "keystores ready: deployer $DEPLOYER, lender $LENDER, borrower $BORROWER, stranger $STRANGER"

# Deploy with the same flag names as the live command.
forge script script/Deploy.s.sol:Deploy --rpc-url "$RPC" --keystore "$KS/deployer" --password-file "$PW" \
  --sender "$DEPLOYER" --broadcast --slow --priority-gas-price 1gwei --with-gas-price 3gwei \
  >"$TMP/deploy.log" 2>&1 || {
  tail -n 30 "$TMP/deploy.log" >&2
  fail "the deploy script failed"
}
TOKEN="$(grep -E '^ *MockStablecoin 0x' "$TMP/deploy.log" | awk '{print $2}' | head -n 1)"
BOOK="$(grep -E '^ *LoanBook 0x' "$TMP/deploy.log" | awk '{print $2}' | head -n 1)"
[ -n "$TOKEN" ] && [ -n "$BOOK" ] || fail "could not read the contract addresses from the deploy log"
step "deployed MockStablecoin $TOKEN and LoanBook $BOOK"
[ "$(cast call "$BOOK" "TOKEN()(address)" --rpc-url "$RPC")" = "$TOKEN" ] || fail "LoanBook does not point at the token"

# The cycle, signed through keystore files.
bash scripts/cycle.sh --rpc-url "$RPC" --chain-id 31337 --token "$TOKEN" --book "$BOOK" \
  --lender-keystore "$KS/lender" --lender-password-file "$PW" --lender-address "$LENDER" \
  --borrower-keystore "$KS/borrower" --borrower-password-file "$PW" --borrower-address "$BORROWER" \
  --evidence "$TMP/cycle-evidence.json" | sed 's/^/cycle: /'
[ "$(tail -n 1 "$TMP/cycle-evidence.json" | grep -c '"finalStatus":3')" = "1" ] || fail "the cycle evidence does not show status 3"
step "cycle-ok, evidence has finalStatus 3"

# ------------------------------------------------------------------ helpers for the scenarios

send() { # WHO TARGET SIG ARGS... : a signed transaction that must succeed
  local who="$1" target="$2" out
  shift 2
  out="$(cast send "$target" "$@" --keystore "$KS/$who" --password-file "$PW" --rpc-url "$RPC" --json)" ||
    fail "a transaction from $who failed: $*"
  case "$out" in
    *'"status":"0x1"'* | *'"status": "0x1"'*) ;;
    *) fail "a transaction from $who did not succeed: $*" ;;
  esac
}

must_revert() { # WHO TARGET SIG ARGS... : a signed transaction that must not succeed
  local who="$1" target="$2" out
  shift 2
  if out="$(cast send "$target" "$@" --gas-limit 500000 --keystore "$KS/$who" --password-file "$PW" --rpc-url "$RPC" --json 2>&1)"; then
    case "$out" in
      *'"status":"0x1"'* | *'"status": "0x1"'*) fail "a transaction from $who succeeded but had to revert: $*" ;;
    esac
  fi
  case "$out" in
    *'"status":"0x0"'* | *'"status": "0x0"'*) echo "  refused as expected: mined and reverted on chain (status 0x0)" ;;
    *) echo "  refused as expected: rejected before mining" ;;
  esac
}

field() { # LOANID N : field N of getLoan
  cast call "$BOOK" "getLoan(uint256)((address,uint16,uint32,uint8,uint8,address,uint64,uint128,uint128,uint128))" "$1" --rpc-url "$RPC" |
    tr -d '()' | awk -F', ' -v n="$2" 'NR == 1 { split($n, a, " "); print a[1] }'
}

counter() { # ADDRESS N : field N of reputationOf
  cast call "$BOOK" "reputationOf(address)((uint32,uint32,uint32))" "$1" --rpc-url "$RPC" |
    tr -d '()' | awk -F', ' -v n="$2" 'NR == 1 { split($n, a, " "); print a[1] }'
}

amount_due() { # LOANID : amountDue of the current installment
  cast call "$BOOK" "nextInstallment(uint256)(uint256,uint256,uint256)" "$1" --rpc-url "$RPC" | sed -n 3p | first
}

now() { cast block latest --field timestamp --rpc-url "$RPC" | first; }

advance() { # SECONDS
  cast rpc evm_increaseTime "$1" --rpc-url "$RPC" >/dev/null
  cast rpc evm_mine --rpc-url "$RPC" >/dev/null
}

next_block_at() { # UNIX_SECONDS : the next mined block gets exactly this timestamp
  cast rpc evm_setNextBlockTimestamp "$1" --rpc-url "$RPC" >/dev/null
}

P=10000000 # 10 tokens per scenario loan, one installment, one day, 10 percent
RATE=1000
SCEN_TOTAL="$(cast call "$BOOK" "totalDueFor(uint256,uint256,uint256)(uint256)" "$P" "$RATE" 1 --rpc-url "$RPC" | first)"

# Tokens for the three scenarios, far below the public mint caps.
send lender "$TOKEN" "mint(uint256)" 30000000
send borrower "$TOKEN" "mint(uint256)" 1000000

new_funded_loan() { # prints the id of a funded one installment loan
  send borrower "$BOOK" "requestLoan(uint256,uint16,uint32,uint8)" "$P" "$RATE" 1 1
  local id
  id="$(cast call "$BOOK" "loanCount()(uint256)" --rpc-url "$RPC" | first)"
  send lender "$TOKEN" "approve(address,uint256)" "$BOOK" "$P"
  send borrower "$TOKEN" "approve(address,uint256)" "$BOOK" "$SCEN_TOTAL"
  send lender "$BOOK" "fund(uint256)" "$id"
  [ "$(field "$id" 5)" = "2" ] || fail "loan $id is not Active after the funding"
  printf '%s\n' "$id"
}

# ------------------------------------------------------------------ (a) a late payment

LATE_BEFORE="$(counter "$BORROWER" 2)"
ID_A="$(new_funded_loan)"
advance 172800
send borrower "$BOOK" "repay(uint256,uint256)" "$ID_A" "$(amount_due "$ID_A")"
[ "$(field "$ID_A" 5)" = "3" ] || fail "late payment: loan $ID_A is not Repaid"
[ "$(counter "$BORROWER" 2)" = "$((LATE_BEFORE + 1))" ] || fail "late payment: the late counter did not grow by one"
step "late payment: loan $ID_A Repaid two days after the due time, late counter $LATE_BEFORE to $((LATE_BEFORE + 1))"

# ------------------------------------------------------------------ (b) a default after 8 days

DEF_BEFORE="$(counter "$BORROWER" 3)"
ID_B="$(new_funded_loan)"
advance $((8 * 86400 + 2))
send stranger "$BOOK" "markDefaulted(uint256)" "$ID_B"
[ "$(field "$ID_B" 5)" = "4" ] || fail "default: loan $ID_B is not Defaulted"
[ "$(counter "$BORROWER" 3)" = "$((DEF_BEFORE + 1))" ] || fail "default: the defaulted counter did not grow by one"
must_revert borrower "$BOOK" "repay(uint256,uint256)" "$ID_B" 1
[ "$(field "$ID_B" 5)" = "4" ] || fail "default: loan $ID_B changed after a repayment attempt"
[ "$(field "$ID_B" 10)" = "0" ] || fail "default: a repayment was accepted after the default"
step "default: loan $ID_B marked by a stranger after 8 days, defaulted counter $DEF_BEFORE to $((DEF_BEFORE + 1)), repay refused"

# ------------------------------------------------------------------ (c) the grace boundary

ID_C="$(new_funded_loan)"
DUE_C="$(cast call "$BOOK" "installmentDueAt(uint256,uint256)(uint256)" "$ID_C" 1 --rpc-url "$RPC" | first)"
LIMIT=$((DUE_C + 7 * 86400))
[ "$(now)" -lt "$LIMIT" ] || fail "boundary: the chain is already past the limit"
next_block_at "$LIMIT"
must_revert stranger "$BOOK" "markDefaulted(uint256)" "$ID_C"
[ "$(field "$ID_C" 5)" = "2" ] || fail "boundary: loan $ID_C was defaulted exactly 7 days after the due time"
next_block_at $((LIMIT + 1))
send stranger "$BOOK" "markDefaulted(uint256)" "$ID_C"
[ "$(field "$ID_C" 5)" = "4" ] || fail "boundary: loan $ID_C was not defaulted one second after the limit"
step "grace boundary: markDefaulted failed at due + 7 days exactly and worked one second later (loan $ID_C)"

echo "rehearsal-ok"
echo "MockStablecoin $TOKEN"
echo "LoanBook $BOOK"
