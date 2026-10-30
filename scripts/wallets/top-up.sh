#!/usr/bin/env bash
# Top-up of the demo wallet pool, paid by the deployer wallet.
#   bash scripts/wallets/top-up.sh --to ROLE|all --amount POL [--dry-run]
# "all" means every pool wallet except the deployer. The amount is in POL, at most 1 POL per
# transfer. --dry-run prints the plan and sends nothing.
# Exit codes: 0 done, 1 deployer balance too low, 2 bad usage, 3 RPC missing or not chain id 80002.
# The RPC URL, keystore password and keys are never printed. Needs cast and jq. Bash 3.2 safe.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CAP_WEI="1000000000000000000" # 1 POL per transfer

to=""
amount=""
dry=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --to)
      [ "$#" -ge 2 ] || die 2 "--to needs a value"
      to="$2"
      shift 2
      ;;
    --amount)
      [ "$#" -ge 2 ] || die 2 "--amount needs a value"
      amount="$2"
      shift 2
      ;;
    --dry-run)
      dry=1
      shift
      ;;
    *) die 2 "usage: top-up.sh --to ROLE|all --amount POL [--dry-run]" ;;
  esac
done
[ -n "$to" ] || die 2 "missing --to"
[ -n "$amount" ] || die 2 "missing --amount"

amount_wei="$(pol_to_wei "$amount")" || die 2 "invalid amount '$amount' (use a decimal number of POL)"
[ "$amount_wei" != "0" ] || die 2 "amount must be greater than zero"
wei_ge "$CAP_WEI" "$amount_wei" || die 2 "amount $amount POL is above the cap of 1 POL per transfer"

require_manifest

roles=""
if [ "$to" = "all" ]; then
  for r in $(manifest_roles); do
    [ "$r" = "deployer" ] || roles="$roles $r"
  done
else
  [ "$to" != "deployer" ] || die 2 "the deployer cannot top up itself"
  manifest_roles | grep -qx -- "$to" || die 2 "unknown role: $to"
  roles=" $to"
fi

require_amoy

count=0
total_wei="0"
for r in $roles; do
  count=$((count + 1))
  total_wei="$(wei_add "$total_wei" "$amount_wei")"
done

deployer_addr="$(role_address deployer)"
keystore="$LATIFI_HOME/keystores/deployer"
password_file="$LATIFI_HOME/keystore-password"

echo "plan: $count transfer(s) of $(wei_to_pol "$amount_wei") POL from deployer $deployer_addr"
for r in $roles; do
  echo "  $r $(role_address "$r")"
done

if [ "$dry" -eq 1 ]; then
  echo "dry run: nothing was sent"
  exit 0
fi

[ -f "$keystore" ] || die 2 "deployer keystore not found in $LATIFI_HOME/keystores"
[ -f "$password_file" ] || die 2 "keystore password file not found in $LATIFI_HOME"

deployer_bal="$(cast balance "$deployer_addr" 2>/dev/null)" || die 3 "could not read the deployer balance"
wei_ge "$deployer_bal" "$total_wei" ||
  die 1 "deployer holds $(wei_to_pol "$deployer_bal") POL, needs at least $(wei_to_pol "$total_wei") POL plus gas"

for r in $roles; do
  to_addr="$(role_address "$r")"
  receipt="$(cast send "$to_addr" --value "$amount_wei" --keystore "$keystore" \
    --password-file "$password_file" --json 2>/dev/null)" || die 1 "transfer to $r failed"
  hash="$(printf '%s' "$receipt" | jq -r '.transactionHash')"
  echo "sent $r $to_addr tx $hash"
done
