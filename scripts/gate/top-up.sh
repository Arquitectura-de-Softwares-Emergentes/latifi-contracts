#!/usr/bin/env bash
# Top-up for the gate wallets: moves test POL from a funded keystore account, or mints test
# stablecoin (tUSD) through the minter role. Dry run by default: it prints the full plan and every
# pre-check and sends nothing unless --execute is given.
#
#   bash scripts/gate/top-up.sh --what pol  --to borrower --amount 0.5 --from-account latifi-deployer
#   bash scripts/gate/top-up.sh --what tusd --to lender   --amount 500 --from-account latifi-deployer --execute
#
# Required:
#   --what pol|tusd        which asset
#   --to lender|borrower|deployer|0xADDRESS
#   --amount DECIMAL       POL (up to 18 decimals) or tUSD (up to 6 decimals)
#   --from-account NAME    Foundry keystore account by name (~/.foundry/keystores/NAME)
#     or --from-keystore PATH [--password-file PATH]
# Optional:
#   --lender ADDR --borrower ADDR   override the public demo addresses
#   --deployments FILE              [deployments/amoy.json]
#   --execute                       really send (without it nothing is sent)
#
# Signing happens only through a Foundry keystore. There is no flag for a password or a private
# key and the script never reads one: cast asks for the password at its own prompt, or reads the
# file whose PATH you give it. The RPC URL reaches cast only through ETH_RPC_URL.
#
# Refusals (exit 1, nothing signed): POL above 1 per transfer, a sender that cannot cover the
# amount plus a 0.02 POL gas reserve, a mint above 10,000 tokens per call, a sender without the
# MINTER_ROLE read from the token, a mint beyond the per address cap headroom.
#
# Exit codes: 0 done or dry run ok, 1 a pre-check refused, 2 bad usage or a chain other than
# 80002, 3 RPC missing or unreachable, 5 the send failed.
# Needs cast and jq. Compatible with bash 3.2.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

POL_CAP_WEI="1000000000000000000"       # 1 POL per transfer
GAS_RESERVE_WEI="20000000000000000"     # 0.02 POL kept for gas by the sender

what=""
to=""
amount=""
from_account=""
from_keystore=""
password_file=""
lender="$DEMO_LENDER"
borrower="$DEMO_BORROWER"
deployments="$DEFAULT_DEPLOYMENTS"
execute=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --execute)
      execute=1
      shift
      ;;
    --what | --to | --amount | --from-account | --from-keystore | --password-file | --lender | \
      --borrower | --deployments)
      need_value "$1" "$#" "${2:-}"
      case "$1" in
        --what) what="$2" ;;
        --to) to="$2" ;;
        --amount) amount="$2" ;;
        --from-account) from_account="$2" ;;
        --from-keystore) from_keystore="$2" ;;
        --password-file) password_file="$2" ;;
        --lender) lender="$2" ;;
        --borrower) borrower="$2" ;;
        --deployments) deployments="$2" ;;
      esac
      shift 2
      ;;
    *) die 2 "unknown argument '$1' (usage: top-up.sh --what pol|tusd --to WHO --amount N --from-account NAME [--execute])" ;;
  esac
done

# ---------------------------------------------------------------- validation (exit 2)

case "$what" in
  pol | tusd) ;;
  '') die 2 "missing --what (pol or tusd)" ;;
  *) die 2 "--what must be pol or tusd" ;;
esac
[ -n "$to" ] || die 2 "missing --to"
[ -n "$amount" ] || die 2 "missing --amount"
for a in "$lender" "$borrower"; do
  is_address "$a" || die 2 "not an address: $a"
done

if [ -n "$from_account" ] && [ -n "$from_keystore" ]; then
  die 2 "give --from-account or --from-keystore, not both"
fi
if [ -z "$from_account" ] && [ -z "$from_keystore" ]; then
  die 2 "missing the sender: use --from-account NAME or --from-keystore PATH"
fi
if [ -n "$from_account" ]; then
  is_safe_name "$from_account" || die 2 "--from-account must be a keystore account name"
  [ -z "$password_file" ] || die 2 "--password-file only goes with --from-keystore"
  SIGN=(--account "$from_account")
else
  if [ -n "$password_file" ]; then
    SIGN=(--keystore "$from_keystore" --password-file "$password_file")
  else
    SIGN=(--keystore "$from_keystore")
  fi
fi

case "$what" in
  pol)
    amount_base="$(pol_to_wei "$amount")" || die 2 "invalid amount '$amount' (a decimal number of POL)"
    unit="POL"
    ;;
  tusd)
    amount_base="$(parse_token_amount "$amount")" || die 2 "invalid amount '$amount' (a decimal number of tUSD, up to $TOKEN_DECIMALS decimals)"
    unit="tUSD"
    ;;
esac
[ "$amount_base" != "0" ] || die 2 "amount must be greater than zero"

if [ "$what" = tusd ]; then
  token="$(read_token_address "$deployments")"
fi

case "$to" in
  lender)
    recipient="$lender"
    to_label="lender"
    ;;
  borrower)
    recipient="$borrower"
    to_label="borrower"
    ;;
  deployer)
    recipient=""
    if [ -f "$deployments" ]; then
      recipient="$(jq -r '.deployer // empty' "$deployments" 2>/dev/null || true)"
    fi
    is_address "$recipient" || recipient="$DEMO_DEPLOYER"
    to_label="deployer"
    ;;
  0x*)
    is_address "$to" || die 2 "not an address: $to"
    recipient="$to"
    to_label="address"
    ;;
  *) die 2 "--to must be lender, borrower, deployer or a 0x address" ;;
esac

# ---------------------------------------------------------------- chain guard (exit 3 or 2)

require_amoy_strict

# The sender address comes from the keystore through cast. cast may ask for the password here, at
# its own prompt. Its error output goes through a file and a scrubber so no URL is ever shown.
errfile="$(mktemp)"
trap 'rm -f "$errfile"' EXIT
sender="$(cast wallet address "${SIGN[@]}" 2>"$errfile")" || {
  scrub_urls <"$errfile" >&2
  die 2 "could not read the sender address from the keystore"
}
is_address "$sender" || die 2 "cast did not answer an address for the sender"

# ---------------------------------------------------------------- plan and pre-checks

refused=0
refuse() {
  refused=$((refused + 1))
  echo "  check REFUSED: $*"
}
passed() {
  echo "  check ok: $*"
}

echo "plan: top up $to_label with $(if [ "$what" = pol ]; then wei_to_pol "$amount_base"; else format_token "$amount_base"; fi) $unit"
echo "  chain       $EXPECTED_CHAIN_ID"
echo "  sender      $sender"
echo "  recipient   $recipient ($to_label)"
if [ "$what" = pol ]; then
  echo "  asset       POL (native), $amount_base wei"
else
  echo "  asset       tUSD at $token, $amount_base base units, through mintTo(address,uint256)"
fi
echo "  gas flags   $AMOY_GAS_FLAGS"

sender_pol="$(cast balance "$sender" 2>/dev/null)" || die 3 "could not read the sender balance"
case "$sender_pol" in '' | *[!0-9]*) die 3 "unexpected sender balance answer" ;; esac
sender_pol="$(wei_norm "$sender_pol")"

if [ "$what" = pol ]; then
  if wei_ge "$POL_CAP_WEI" "$amount_base"; then
    passed "amount is within the cap of 1 POL per transfer"
  else
    refuse "amount $(wei_to_pol "$amount_base") POL is above the cap of 1 POL per transfer"
  fi
  need="$(wei_add "$amount_base" "$GAS_RESERVE_WEI")"
  if wei_ge "$sender_pol" "$need"; then
    passed "sender holds $(wei_to_pol "$sender_pol") POL, needs $(wei_to_pol "$need") POL (amount plus 0.02 POL for gas)"
  else
    refuse "sender holds $(wei_to_pol "$sender_pol") POL, needs $(wei_to_pol "$need") POL (amount plus 0.02 POL for gas)"
  fi
else
  if wei_ge "$MINT_CALL_CAP_BASE" "$amount_base"; then
    passed "amount is within the cap of 10000 tUSD per mint call"
  else
    refuse "amount $(format_token "$amount_base") tUSD is above the cap of 10000 tUSD per mint call"
  fi
  if wei_ge "$sender_pol" "$GAS_RESERVE_WEI"; then
    passed "sender holds $(wei_to_pol "$sender_pol") POL, at least the 0.02 POL gas reserve"
  else
    refuse "sender holds $(wei_to_pol "$sender_pol") POL, less than the 0.02 POL gas reserve"
  fi
  role="$(cast call "$token" "MINTER_ROLE()(bytes32)" 2>/dev/null | first_token)" || die 3 "could not read MINTER_ROLE from the token"
  printf '%s' "$role" | grep -Eq '^0x[0-9a-fA-F]{64}$' || die 3 "unexpected MINTER_ROLE answer from the token"
  has_role="$(cast call "$token" "hasRole(bytes32,address)(bool)" "$role" "$sender" 2>/dev/null | first_token)" || die 3 "could not read hasRole from the token"
  if [ "$has_role" = true ]; then
    passed "sender holds the MINTER_ROLE of the token"
  else
    refuse "sender $sender does not hold the MINTER_ROLE of the token, use the deployer account"
  fi
  minted="$(cast_uint "$token" "mintedTo(address)(uint256)" "$recipient")" || die 3 "could not read mintedTo of the recipient"
  minted="$(wei_norm "$minted")"
  if wei_ge "$MINT_ADDRESS_CAP_BASE" "$minted"; then
    headroom=$((MINT_ADDRESS_CAP_BASE - minted))
  else
    headroom=0
  fi
  if wei_ge "$headroom" "$amount_base"; then
    passed "recipient has $(format_token "$headroom") tUSD of mint headroom"
  else
    refuse "recipient has only $(format_token "$headroom") tUSD of mint headroom: it can no longer be topped up by minting, use a new wallet"
  fi
fi

if [ "$refused" -gt 0 ]; then
  echo "refused: $refused check(s) failed, nothing was signed or sent"
  exit 1
fi

if [ "$execute" -eq 0 ]; then
  echo "dry run: nothing was sent (add --execute to send)"
  exit 0
fi

# ---------------------------------------------------------------- send (exit 5 on failure)

# $AMOY_GAS_FLAGS is two flag/value pairs of fixed text, so word splitting is intended here.
if [ "$what" = pol ]; then
  # shellcheck disable=SC2086
  receipt="$(cast send "$recipient" --value "$amount_base" "${SIGN[@]}" $AMOY_GAS_FLAGS --json 2>"$errfile")" || {
    scrub_urls <"$errfile" >&2
    die 5 "the POL transfer failed"
  }
else
  # shellcheck disable=SC2086
  receipt="$(cast send "$token" "mintTo(address,uint256)" "$recipient" "$amount_base" "${SIGN[@]}" $AMOY_GAS_FLAGS --json 2>"$errfile")" || {
    scrub_urls <"$errfile" >&2
    die 5 "the mint failed"
  }
fi

hash="$(printf '%s' "$receipt" | jq -r '.transactionHash // empty' 2>/dev/null || true)"
status="$(printf '%s' "$receipt" | jq -r '.status // empty' 2>/dev/null || true)"
case "$status" in
  0x1 | 1 | success) ;;
  *) die 5 "the transaction was not successful (status '${status:-unknown}', hash '${hash:-unknown}')" ;;
esac
blk="$(printf '%s' "$receipt" | jq -r '.blockNumber // empty' 2>/dev/null || true)"
case "$blk" in
  0x[0-9a-fA-F]*) blk=$((blk)) ;;
  *[!0-9]*) blk="unknown" ;;
esac
echo "sent: tx $hash in block ${blk:-unknown}"

if [ "$what" = pol ]; then
  new_bal="$(cast balance "$recipient" 2>/dev/null)" || die 5 "sent, but could not read the new balance back"
  echo "new balance of $recipient: $(wei_to_pol "$new_bal") POL"
else
  new_bal="$(cast_uint "$token" "balanceOf(address)(uint256)" "$recipient")" || die 5 "sent, but could not read the new balance back"
  echo "new balance of $recipient: $(format_token "$new_bal") tUSD"
fi
exit 0
