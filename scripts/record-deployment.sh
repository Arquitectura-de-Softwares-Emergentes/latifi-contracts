#!/usr/bin/env bash
# record-deployment.sh: turns a forge broadcast file into the deployment record that the other
# repos read (deployments/amoy.json).
#
# Usage: record-deployment.sh BROADCAST_JSON RELEASE_TAG [--chain-id N] > deployments/amoy.json
#   BROADCAST_JSON  the run-latest.json that forge script wrote under broadcast/Deploy.s.sol/CHAIN/
#   RELEASE_TAG     the release the deployment belongs to, vMAJOR.MINOR.PATCH, for example v0.2.0
#   --chain-id N    80002 (default, Polygon Amoy) or 31337 (local chain). Nothing else is accepted.
#
# The record goes to stdout with sorted keys. Exit codes: 0 done, 1 the broadcast does not look
# like the expected deployment (wrong chain, bad tag, not exactly MockStablecoin then LoanBook,
# or a receipt that is not a success), 2 bad usage or a chain outside the allow-list.
#
# Needs jq and forge. Works on bash 3.2 and bash 5.

set -eu

die() {
  local code="$1"
  shift
  echo "record-deployment: $*" >&2
  exit "$code"
}

RUN=""
TAG=""
CHAIN_ID="80002"
POS=0
while [ $# -gt 0 ]; do
  case "$1" in
    --chain-id)
      [ $# -ge 2 ] || die 2 "--chain-id needs a value"
      CHAIN_ID="$2"
      shift 2
      ;;
    -h | --help)
      sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*) die 2 "unknown option: $1" ;;
    *)
      POS=$((POS + 1))
      case "$POS" in
        1) RUN="$1" ;;
        2) TAG="$1" ;;
        *) die 2 "unexpected argument: $1" ;;
      esac
      shift
      ;;
  esac
done

[ -n "$RUN" ] && [ -n "$TAG" ] || die 2 "usage: record-deployment.sh BROADCAST_JSON RELEASE_TAG [--chain-id N]"

# Allow-list of chains.
case "$CHAIN_ID" in
  80002) NETWORK="polygon-amoy" ;;
  31337) NETWORK="local" ;;
  *) die 2 "chain id '$CHAIN_ID' is not allowed, use the Polygon Amoy testnet or the local chain" ;;
esac

command -v jq >/dev/null 2>&1 || die 2 "jq is not installed"
command -v forge >/dev/null 2>&1 || die 2 "forge is not installed"
[ -f "$RUN" ] || die 2 "broadcast file not found: $RUN"
jq -e . "$RUN" >/dev/null 2>&1 || die 1 "the broadcast file is not valid JSON"

printf '%s' "$TAG" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$' ||
  die 1 "release tag '$TAG' must look like v0.2.0 (v, then MAJOR.MINOR.PATCH)"

[ "$(jq -r '.chain' "$RUN")" = "$CHAIN_ID" ] ||
  die 1 "the broadcast is for chain $(jq -r '.chain' "$RUN"), expected $CHAIN_ID"

jq -e '[.transactions[] | select(.transactionType == "CREATE") | .contractName] == ["MockStablecoin", "LoanBook"]' "$RUN" >/dev/null ||
  die 1 "the broadcast must hold exactly two CREATE transactions, MockStablecoin first and LoanBook second"

jq -e '
  [.transactions[] | select(.transactionType == "CREATE") | .hash] as $hashes
  | ([.receipts[].transactionHash] | sort) == ($hashes | sort)
  and ([.receipts[].status] | all(. == "0x1"))' "$RUN" >/dev/null ||
  die 1 "every CREATE transaction needs a receipt with status 0x1, and nothing else may be in the receipts"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
(cd "$ROOT" && forge inspect src/MockStablecoin.sol:MockStablecoin abi --json) >"$TMP/token.abi" ||
  die 1 "forge inspect failed for MockStablecoin"
(cd "$ROOT" && forge inspect src/LoanBook.sol:LoanBook abi --json) >"$TMP/book.abi" ||
  die 1 "forge inspect failed for LoanBook"

jq -S --arg tag "$TAG" --arg network "$NETWORK" \
  --slurpfile token "$TMP/token.abi" --slurpfile book "$TMP/book.abi" '
  . as $run
  | ([.transactions[] | select(.transactionType == "CREATE")]) as $creates
  | {MockStablecoin: $token[0], LoanBook: $book[0]} as $abis
  | {
      chainId: .chain,
      network: $network,
      release: $tag,
      commit: .commit,
      deployedAtMs: .timestamp,
      deployer: ($creates[0].transaction.from | ascii_downcase),
      contracts: (
        reduce $creates[] as $c ({};
          .[$c.contractName] = {
            address: $c.contractAddress,
            creationTx: $c.hash,
            blockNumber: ([$run.receipts[] | select(.transactionHash == $c.hash) | .blockNumber][0]),
            constructorArgs: $c.arguments,
            abi: $abis[$c.contractName]
          })
      )
    }' "$RUN"
