#!/usr/bin/env bash
# check-testnet-only.test.sh: fixture suite for check-testnet-only.sh.
#
# Each case builds a throwaway git repository, runs the guard inside it and compares the exit code.
# Forbidden strings are assembled from pieces at runtime so this file never holds a complete
# key-shaped literal.
#
# Works on macOS bash 3.2 and Ubuntu bash 5.

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
GUARD="$HERE/check-testnet-only.sh"

TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

TOTAL=0
PASSED=0

# make_repo DIR: create a clean repo whose foundry.toml names the Amoy chain id.
make_repo() {
  mkdir -p "$1"
  (
    cd "$1" || exit 1
    git init -q
    git config user.email "test@example.com"
    git config user.name "Test"
    printf '%s\n' '# Polygon Amoy chain id 80002' > foundry.toml
    printf '%s\n' 'contract A {}' > A.sol
    git add foundry.toml A.sol
  )
}

# add_file DIR NAME CONTENT: write a tracked file into the repo.
add_file() {
  printf '%s\n' "$3" > "$1/$2"
  git -C "$1" add "$2"
}

# expect NAME EXPECTED_EXIT DIR
expect() {
  TOTAL=$((TOTAL + 1))
  (cd "$3" && bash "$GUARD" > "$TMP_ROOT/out.txt" 2>&1)
  code=$?
  if [ "$code" -eq "$2" ]; then
    PASSED=$((PASSED + 1))
    echo "ok $TOTAL $1"
  else
    echo "not ok $TOTAL $1 (exit $code, expected $2)"
    sed 's/^/    /' "$TMP_ROOT/out.txt"
  fi
}

# Pieces used to build forbidden strings.
ONE="1"
POLY="137"
KEY16="abcdefghij0123456789"
HEX8="0123abcd"
HEX64="${HEX8}${HEX8}${HEX8}${HEX8}${HEX8}${HEX8}${HEX8}${HEX8}"

# 1. A clean repo passes.
D="$TMP_ROOT/clean"
make_repo "$D"
expect "clean repo passes" 0 "$D"

# 2. Amoy chain id assignment and a harmless 1337 pass.
D="$TMP_ROOT/amoy"
make_repo "$D"
add_file "$D" config.toml "chain_id = 80002
local_chain_id = 1337"
expect "chain ids 80002 and 1337 pass" 0 "$D"

# 3. A 64 hex value without a private key name passes.
D="$TMP_ROOT/hexok"
make_repo "$D"
add_file "$D" hashes.txt "tx_hash = 0x${HEX64}"
expect "64 hex value without a private key name passes" 0 "$D"

# 4. Polygon PoS chain id fails.
D="$TMP_ROOT/poly"
make_repo "$D"
add_file "$D" config.toml "chain_id = ${POLY}"
expect "chain_id = 137 fails" 1 "$D"

# 5. Ethereum chain id in a CLI flag fails.
D="$TMP_ROOT/flag"
make_repo "$D"
add_file "$D" deploy.sh "forge script Deploy --chain ${ONE}"
expect "--chain 1 fails" 1 "$D"

# 6. camelCase chain id fails.
D="$TMP_ROOT/camel"
make_repo "$D"
add_file "$D" net.ts "const net = { chainId: ${POLY} };"
expect "chainId: 137 fails" 1 "$D"

# 7. Mainnet RPC host fails.
D="$TMP_ROOT/host"
make_repo "$D"
add_file "$D" rpc.txt "https://polygon""-rpc.com"
expect "polygon mainnet RPC host fails" 1 "$D"

# 8. Mainnet RPC host through a provider name fails.
D="$TMP_ROOT/host2"
make_repo "$D"
add_file "$D" rpc.txt "https://eth""-mainnet.example.org"
expect "eth mainnet host fails" 1 "$D"

# 9. Alchemy URL with a key fails.
D="$TMP_ROOT/alchemy"
make_repo "$D"
add_file "$D" rpc.txt "https://polygon-amoy.g.alchemy.com/v2/${KEY16}"
expect "alchemy URL with a key fails" 1 "$D"

# 10. Infura URL with a key fails.
D="$TMP_ROOT/infura"
make_repo "$D"
add_file "$D" rpc.txt "https://polygon-amoy.infura.io/v3/${KEY16}"
expect "infura URL with a key fails" 1 "$D"

# 11. 64 hex value on a private key line fails.
D="$TMP_ROOT/privkey"
make_repo "$D"
add_file "$D" env.txt "PRIVATE_KEY=0x${HEX64}"
expect "64 hex value on a private key line fails" 1 "$D"

# 12. foundry.toml without 80002 fails.
D="$TMP_ROOT/no80002"
make_repo "$D"
printf '%s\n' '[profile.default]' > "$D/foundry.toml"
git -C "$D" add foundry.toml
expect "foundry.toml without 80002 fails" 1 "$D"

# 13. Untracked offending files are ignored.
D="$TMP_ROOT/untracked"
make_repo "$D"
printf '%s\n' "chain_id = ${POLY}" > "$D/scratch.toml"
expect "untracked files are not scanned" 0 "$D"

echo "PASS $PASSED/$TOTAL"
[ "$PASSED" -eq "$TOTAL" ]
