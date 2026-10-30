#!/usr/bin/env bash
# check-testnet-only.sh: repository guard for the testnet-only rule (TC-01) and for committed secrets.
#
# Run it from anywhere inside the repository. It scans tracked files only and fails with exit code 1
# and one `file:line: reason` line per finding when it sees:
#   a. a mainnet chain id assignment for Ethereum (1) or Polygon PoS (137)
#   b. a mainnet RPC host
#   c. a secret-shaped literal: an Alchemy or Infura URL with a long key segment, or a 64 character
#      hex value on a line that also names a private key
# It also fails when foundry.toml does not name the Polygon Amoy chain id 80002.
#
# Works on macOS bash 3.2 and Ubuntu bash 5.

set -u

ROOT=$(git rev-parse --show-toplevel 2> /dev/null) || {
  echo "testnet-only: not inside a git repository" >&2
  exit 2
}
cd "$ROOT" || exit 2

SELF="scripts/check-testnet-only.sh"
SELF_TEST="scripts/check-testnet-only.test.sh"

FINDINGS=$(mktemp)
trap 'rm -f "$FINDINGS"' EXIT

# scan FILE REGEX REASON: append `file:line: reason` for every matching line.
scan() {
  grep -n -I -i -E -e "$2" -- "$1" 2> /dev/null | cut -d: -f1 | while IFS= read -r line; do
    echo "$1:$line: $3" >> "$FINDINGS"
  done
}

CHAIN_ID_RE='(chain_id|chainid|chain-id|--chain)[[:space:]]*[=:]?[[:space:]]*["'"'"']?(1|137)([^0-9a-z_]|$)'
MAINNET_HOST_RE='polygon-rpc\.com|polygon-mainnet|eth-mainnet|mainnet\.infura\.io'
ALCHEMY_KEY_RE='alchemy\.com/v2/[A-Za-z0-9_-]{16,}'
INFURA_KEY_RE='infura\.io/v3/[A-Za-z0-9]{16,}'

git ls-files | while IFS= read -r f; do
  [ "$f" = "$SELF" ] && continue
  [ "$f" = "$SELF_TEST" ] && continue
  [ -f "$f" ] || continue

  scan "$f" "$CHAIN_ID_RE" "mainnet chain id (1 or 137) is not allowed, use Polygon Amoy 80002"
  scan "$f" "$MAINNET_HOST_RE" "mainnet RPC host is not allowed"
  scan "$f" "$ALCHEMY_KEY_RE" "Alchemy URL with an API key must not be committed"
  scan "$f" "$INFURA_KEY_RE" "Infura URL with an API key must not be committed"

  # A 64 hex value only counts when the same line names a private key.
  grep -n -I -i -E -e '(^|[^0-9a-f])[0-9a-f]{64}([^0-9a-f]|$)' -- "$f" 2> /dev/null \
    | grep -i -E 'priv(ate)?[_ -]?key' | cut -d: -f1 | while IFS= read -r line; do
      echo "$f:$line: 64 hex value on a private key line must not be committed" >> "$FINDINGS"
    done
done

if [ ! -f foundry.toml ] || ! grep -q '80002' foundry.toml; then
  echo "foundry.toml:1: must name the Polygon Amoy chain id 80002" >> "$FINDINGS"
fi

if [ -s "$FINDINGS" ]; then
  sort -u "$FINDINGS"
  echo "testnet-only: FAIL"
  exit 1
fi

echo "testnet-only: ok"
