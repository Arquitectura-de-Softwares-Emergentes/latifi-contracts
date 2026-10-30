#!/usr/bin/env bash
# Creates the six demo wallets as encrypted keystores OUTSIDE every repository and writes the
# public manifest deployments/demo-wallets.json (roles, addresses, minimum balances).
#
# Secrets live in ~/.latifi (directory mode 700): keystore-password (mode 600) and keystores/.
# This script prints addresses only. It never prints key material or the password, and it never
# overwrites an existing keystore. The keys hold worthless testnet POL and must never hold value.
# Needs cast and jq. Compatible with bash 3.2. Makes no network call.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROLES="deployer lender-1 lender-2 borrower-1 borrower-2 borrower-3"
KEYSTORE_DIR="$LATIFI_HOME/keystores"
PASSWORD_FILE="$LATIFI_HOME/keystore-password"

# The secret directory must never sit inside a git working tree.
mkdir -p "$LATIFI_HOME"
chmod 700 "$LATIFI_HOME"
if git -C "$LATIFI_HOME" rev-parse --git-dir >/dev/null 2>&1; then
  die 2 "$LATIFI_HOME is inside a git repository, refusing to store keys there"
fi

mkdir -p "$KEYSTORE_DIR"
chmod 700 "$KEYSTORE_DIR"

if [ ! -f "$PASSWORD_FILE" ]; then
  (umask 077 && openssl rand -hex 24 >"$PASSWORD_FILE")
fi
chmod 600 "$PASSWORD_FILE"

rows=""
for role in $ROLES; do
  file="$KEYSTORE_DIR/$role"
  if [ -e "$file" ]; then
    echo "keep   $role (keystore already exists)"
  else
    # The password travels in the environment of this one command, not on the command line.
    CAST_PASSWORD="$(cat "$PASSWORD_FILE")" cast wallet new "$KEYSTORE_DIR" "$role" >/dev/null 2>&1 ||
      die 1 "cast could not create the keystore for $role"
    chmod 600 "$file"
    echo "create $role"
  fi
  raw="$(jq -r '.address' "$file")"
  addr="$(cast to-check-sum-address "0x${raw#0x}")"
  case "$addr" in
    0x????????????????????????????????????????) ;;
    *) die 1 "unexpected address for $role" ;;
  esac
  rows="$rows$(jq -nc --arg r "$role" --arg a "$addr" '{role: $r, address: $a}')
"
  echo "       $role $addr"
done

mkdir -p "$(dirname "$MANIFEST")"
tmp="$(mktemp)"
printf '%s' "$rows" | jq -s '{
  chainId: 80002,
  network: "polygon-amoy",
  nativeToken: "POL",
  minBalancePol: {deployer: "0.3", default: "0.1"},
  wallets: .
}' >"$tmp"
mv "$tmp" "$MANIFEST"
chmod 644 "$MANIFEST"
echo "manifest written: ${MANIFEST#"$REPO_ROOT"/}"
