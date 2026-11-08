#!/usr/bin/env bash
# check-deployment.sh: guard for the deployment record (deployments/amoy.json).
#
# Usage: check-deployment.sh [--file PATH] [--chain-id N]
#   --file PATH     the record to check [deployments/amoy.json]
#   --chain-id N    80002 (Polygon Amoy) or 31337 (local chain), nothing else [80002]
#
# Prints "deployment-check: no record yet" and exits 0 when the file does not exist, so the guard
# can run in ci before the first deployment. Otherwise it prints "deployment-check: ok" or one
# "deployment-check: reason" line per finding on stderr and exits 1. Exit 2 is bad usage.
#
# Checks: chain id, release tag form, commit shape, both contracts with address, creation tx and
# block, the LoanBook constructor argument against the token address, the token constructor
# argument against the deployer, the event ABI against abi/loan-events.v0.json, no price-like
# names in either ABI, and no key, mnemonic, password or secret field anywhere in the record.
#
# Needs jq. Works on bash 3.2 and bash 5.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FILE="deployments/amoy.json"
CHAIN_ID="80002"

usage_error() {
  echo "deployment-check: $*" >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --file)
      [ $# -ge 2 ] || usage_error "--file needs a value"
      FILE="$2"
      shift 2
      ;;
    --chain-id)
      [ $# -ge 2 ] || usage_error "--chain-id needs a value"
      CHAIN_ID="$2"
      shift 2
      ;;
    -h | --help)
      sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) usage_error "unknown argument: $1" ;;
  esac
done

# Allow-list of chains.
case "$CHAIN_ID" in
  80002 | 31337) ;;
  *) usage_error "chain id '$CHAIN_ID' is not allowed, use the Polygon Amoy testnet or the local chain" ;;
esac

command -v jq >/dev/null 2>&1 || usage_error "jq is not installed"

if [ ! -f "$FILE" ]; then
  echo "deployment-check: no record yet"
  exit 0
fi

BAD=0
finding() {
  echo "deployment-check: $*" >&2
  BAD=1
}

if ! jq -e . "$FILE" >/dev/null 2>&1; then
  finding "$FILE is not valid JSON"
  exit 1
fi

# expect REASON JQ_FILTER [ARGS...]: the filter must evaluate to true on the record.
expect() {
  local reason="$1" filter="$2"
  shift 2
  jq -e "$@" "$filter" "$FILE" >/dev/null 2>&1 || finding "$reason"
}

expect "chainId is not $CHAIN_ID" '.chainId == ($id | tonumber)' --arg id "$CHAIN_ID"
expect "release must look like v0.2.0" '(.release // "") | type == "string" and test("^v[0-9]+\\.[0-9]+\\.[0-9]+$")'
expect "commit must be 7 to 40 hex characters" '(.commit // "") | type == "string" and test("^[0-9a-fA-F]{7,40}$")'
expect "deployer must be an address" '(.deployer // "") | type == "string" and test("^0x[0-9a-fA-F]{40}$")'
expect "network does not match the chain id" \
  '.network == (if $id == "80002" then "polygon-amoy" else "local" end)' --arg id "$CHAIN_ID"

for name in MockStablecoin LoanBook; do
  expect "$name needs an address of 0x and 40 hex characters" \
    '(.contracts[$n].address // "") | type == "string" and test("^0x[0-9a-fA-F]{40}$")' --arg n "$name"
  expect "$name needs a creationTx of 0x and 64 hex characters" \
    '(.contracts[$n].creationTx // "") | type == "string" and test("^0x[0-9a-fA-F]{64}$")' --arg n "$name"
  expect "$name needs a blockNumber" \
    '(.contracts[$n].blockNumber // null) | ((type == "string" and test("^0x[0-9a-fA-F]+$")) or (type == "number"))' --arg n "$name"
  expect "$name needs an abi array" '(.contracts[$n].abi // null) | type == "array" and length > 0' --arg n "$name"
done

expect "the LoanBook constructor argument must equal the MockStablecoin address" \
  '((.contracts.LoanBook.constructorArgs[0] // "") | ascii_downcase) == ((.contracts.MockStablecoin.address // "x") | ascii_downcase)'
expect "the MockStablecoin constructor argument must equal the deployer" \
  '((.contracts.MockStablecoin.constructorArgs[0] // "") | ascii_downcase) == ((.deployer // "x") | ascii_downcase)'

# Event ABI of the LoanBook against the committed v0 file.
V0="$ROOT/abi/loan-events.v0.json"
if [ -f "$V0" ]; then
  EXPECTED="$(jq -S 'sort_by(.name)' "$V0")"
  ACTUAL="$(jq -S '[(.contracts.LoanBook.abi // [])[] | select(.type == "event")] | sort_by(.name)' "$FILE" 2>/dev/null)"
  [ "$ACTUAL" = "$EXPECTED" ] || finding "the LoanBook event ABI differs from abi/loan-events.v0.json"
else
  finding "abi/loan-events.v0.json is missing, so the event ABI cannot be checked"
fi

# No price-like names in either ABI, at any depth.
BAD_NAMES="$(jq -r '
  [.contracts[]?.abi[]? | .. | objects | .name? // empty | strings
   | select(test("price|fxrate|exchange|oracle"; "i"))] | unique | join(", ")' "$FILE" 2>/dev/null)"
[ -z "$BAD_NAMES" ] || finding "price-like names are not allowed in the ABI: $BAD_NAMES"

# No secret-looking field anywhere in the record.
BAD_KEYS="$(jq -r '[.. | objects | keys[] | select(test("privatekey|mnemonic|password|secret"; "i"))] | unique | join(", ")' "$FILE" 2>/dev/null)"
[ -z "$BAD_KEYS" ] || finding "the record holds a field that looks like a secret: $BAD_KEYS"

if [ "$BAD" -ne 0 ]; then
  exit 1
fi
echo "deployment-check: ok"
