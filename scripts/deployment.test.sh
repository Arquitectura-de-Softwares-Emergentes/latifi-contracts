#!/usr/bin/env bash
# deployment.test.sh: self-test for record-deployment.sh and check-deployment.sh.
#
# A synthetic forge broadcast file (two CREATE transactions and two receipts) goes through the record
# builder, and the record goes through the guard. Every other case mutates the broadcast or the
# record and expects a refusal. Fixtures live under mktemp. Needs jq and forge (the ABI comes from
# forge inspect). Works on macOS bash 3.2 and Ubuntu bash 5.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
RECORD="$HERE/record-deployment.sh"
CHECK="$HERE/check-deployment.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
total=0
expect_rc() { # NAME EXPECTED ACTUAL
  total=$((total + 1))
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1))
    echo "PASS $1"
  else
    fail=$((fail + 1))
    echo "FAIL $1 (expected exit $2, got $3)"
  fi
}
check() { # NAME CONDITION_EXIT_CODE
  total=$((total + 1))
  if [ "$2" = "0" ]; then
    pass=$((pass + 1))
    echo "PASS $1"
  else
    fail=$((fail + 1))
    echo "FAIL $1"
  fi
}
run() { OUT="$("$@" 2>&1)"; RC=$?; }

DEPLOYER="0x5577fc66c64e4749eed2e09E6Cd5A2b0e7F970D6"
TOKEN="0x1111111111111111111111111111111111111111"
BOOK="0x2222222222222222222222222222222222222222"
H1="0x$(printf '%064x' 4097)"
H2="0x$(printf '%064x' 4098)"

# make_broadcast FILE CHAIN : a synthetic broadcast in the shape forge writes.
make_broadcast() {
  jq -n --argjson chain "$2" --arg dep "$DEPLOYER" --arg token "$TOKEN" --arg book "$BOOK" \
    --arg h1 "$H1" --arg h2 "$H2" '
    {
      transactions: [
        {hash: $h1, transactionType: "CREATE", contractName: "MockStablecoin", contractAddress: $token,
         arguments: [$dep], transaction: {from: ($dep | ascii_downcase), to: null, nonce: "0x0"}},
        {hash: $h2, transactionType: "CREATE", contractName: "LoanBook", contractAddress: $book,
         arguments: [$token], transaction: {from: ($dep | ascii_downcase), to: null, nonce: "0x1"}}
      ],
      receipts: [
        {transactionHash: $h1, status: "0x1", blockNumber: "0x10", contractAddress: $token},
        {transactionHash: $h2, status: "0x1", blockNumber: "0x11", contractAddress: $book}
      ],
      libraries: [], pending: [], returns: {},
      timestamp: 1793420399436, chain: $chain, commit: "0c76261"
    }' >"$1"
}

BC="$WORK/broadcast.json"
REC="$WORK/record.json"
make_broadcast "$BC" 80002

# 1. The record builder on a good broadcast.
run bash "$RECORD" "$BC" v0.2.0
expect_rc "record-deployment accepts a good broadcast" 0 "$RC"
bash "$RECORD" "$BC" v0.2.0 >"$REC" 2>/dev/null
check "record has the documented fields" "$(jq -e '
  (keys == ["chainId","commit","contracts","deployedAtMs","deployer","network","release"])
  and .chainId == 80002 and .network == "polygon-amoy" and .release == "v0.2.0"
  and .commit == "0c76261" and .deployedAtMs == 1793420399436
  and .deployer == ("0x5577fc66c64e4749eed2e09e6cd5a2b0e7f970d6")
  and ((.contracts | keys) == ["LoanBook","MockStablecoin"])
  and ([.contracts[] | (keys == ["abi","address","blockNumber","constructorArgs","creationTx"])] | all)
  and .contracts.LoanBook.blockNumber == "0x11" and .contracts.MockStablecoin.blockNumber == "0x10"
  and (.contracts.LoanBook.abi | length) > 0' "$REC" >/dev/null; echo $?)"

# 2. The guard on that record.
run bash "$CHECK" --file "$REC"
expect_rc "check-deployment accepts the record" 0 "$RC"
check "check-deployment prints ok" "$([ "$OUT" = "deployment-check: ok" ]; echo $?)"

# 3. The record builder refuses bad input. These all fail before forge is called.
make_broadcast "$WORK/wrong-chain.json" 31337
run bash "$RECORD" "$WORK/wrong-chain.json" v0.2.0
expect_rc "a broadcast for another chain exits 1" 1 "$RC"

run bash "$RECORD" "$BC" 0.2.0
expect_rc "a tag without the v exits 1" 1 "$RC"
run bash "$RECORD" "$BC" v1.2
expect_rc "a tag without a patch number exits 1" 1 "$RC"

jq '.receipts[1].status = "0x0"' "$BC" >"$WORK/failed.json"
run bash "$RECORD" "$WORK/failed.json" v0.2.0
expect_rc "a failed receipt exits 1" 1 "$RC"

jq '.transactions |= reverse' "$BC" >"$WORK/swapped.json"
run bash "$RECORD" "$WORK/swapped.json" v0.2.0
expect_rc "a swapped contract order exits 1" 1 "$RC"

jq '.transactions += [.transactions[1]]' "$BC" >"$WORK/three.json"
run bash "$RECORD" "$WORK/three.json" v0.2.0
expect_rc "three CREATE transactions exit 1" 1 "$RC"

# 4. The guard without a record.
run bash "$CHECK" --file "$WORK/does-not-exist.json"
expect_rc "no record exits 0" 0 "$RC"
check "no record says so" "$([ "$OUT" = "deployment-check: no record yet" ]; echo $?)"

# 5. The guard refuses tampered records.
mutate() { # NAME JQ_FILTER : a mutated copy of the record must fail the guard
  jq "$2" "$REC" >"$WORK/mutated.json"
  run bash "$CHECK" --file "$WORK/mutated.json"
  expect_rc "$1" 1 "$RC"
}
mutate "a LoanBook constructor argument that is not the token fails" \
  '.contracts.LoanBook.constructorArgs[0] = "0x3333333333333333333333333333333333333333"'
mutate "a token constructor argument that is not the deployer fails" \
  '.contracts.MockStablecoin.constructorArgs[0] = "0x3333333333333333333333333333333333333333"'
mutate "a tampered event name fails" \
  '(.contracts.LoanBook.abi[] | select(.type == "event" and .name == "LoanFunded") | .name) = "LoanFundedX"'
mutate "an injected price-like parameter name fails" \
  '(.contracts.LoanBook.abi[] | select(.type == "event" and .name == "LoanFunded") | .inputs[0].name) = "exchangeRate"'
mutate "a bad release tag in the record fails" '.release = "release-2"'
mutate "a field named privateKey fails" '.deployerInfo = {privateKey: "redacted"}'
mutate "a short creation transaction hash fails" '.contracts.LoanBook.creationTx = "0x1234"'
mutate "a record for another chain fails" '.chainId = 31337'

# 6. The allow-list of chains, in both scripts.
run bash "$RECORD" "$BC" v0.2.0 --chain-id 5
expect_rc "record-deployment --chain-id 5 exits 2" 2 "$RC"
run bash "$CHECK" --file "$REC" --chain-id 5
expect_rc "check-deployment --chain-id 5 exits 2" 2 "$RC"

# 7. The local chain shape.
make_broadcast "$WORK/local.json" 31337
bash "$RECORD" "$WORK/local.json" v0.0.0 --chain-id 31337 >"$WORK/local-record.json" 2>/dev/null
check "a local record names the local network" "$(jq -e '.chainId == 31337 and .network == "local"' "$WORK/local-record.json" >/dev/null; echo $?)"
run bash "$CHECK" --file "$WORK/local-record.json" --chain-id 31337
expect_rc "the guard accepts a local record with --chain-id 31337" 0 "$RC"
run bash "$CHECK" --file "$WORK/local-record.json"
expect_rc "the guard rejects a local record against the default chain" 1 "$RC"

echo "PASS $pass/$total"
[ "$fail" -eq 0 ]
