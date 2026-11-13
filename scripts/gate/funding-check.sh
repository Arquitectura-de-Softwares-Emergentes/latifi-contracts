#!/usr/bin/env bash
# Gate aware funding check: reads POL and test stablecoin (tUSD) of the lender, the borrower and
# the deployer on Polygon Amoy, compares them with stated minimums, prints a table and writes a
# JSON evidence file with public data only.
#
#   bash scripts/gate/funding-check.sh --gate TB2 --gate-at 2026-12-04T23:00:00Z
#
# Required:
#   --gate NAME           TB2 or TF1, or free text for a rehearsal (letters, digits, . _ -)
#   --gate-at ISO         gate time in UTC, written YYYY-MM-DDTHH:MM:SSZ
# Optional:
#   --now ISO             pretend it is this time (tests only; the evidence records the override)
#   --lender ADDR         [public demo lender]      --borrower ADDR [public demo borrower]
#   --deployer ADDR       [public demo deployer]
#   --min-pol-lender X    [0.30]   --min-pol-borrower X [0.30]   --min-pol-deployer X [0.30]
#   --min-tusd-lender X   [500]    --min-tusd-borrower X [50]    (the deployer needs no tUSD)
#   --deployments FILE    [deployments/amoy.json]
#   --evidence FILE       [broadcast/gate-NAME-UTCSTAMP.json]
#   --allow-late          a funded run less than 24 hours before the gate exits 0 but is still
#                         recorded as not qualifying
#
# A run qualifies only when every wallet meets its minimums AND the run happens at least 24 hours
# before the gate. --allow-late never produces qualifying true.
#
# Exit codes: 0 funded and qualifying, 1 any wallet short, 2 bad usage, 3 the RPC is missing,
# unreachable or not chain id 80002, 4 funded but fewer than 24 hours before the gate (not
# qualifying). The RPC URL, keys and passwords are never printed or written to the evidence.
# Needs cast and jq. Compatible with bash 3.2.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

gate=""
gate_at=""
now_arg=""
lender="$DEMO_LENDER"
borrower="$DEMO_BORROWER"
deployer="$DEMO_DEPLOYER"
min_pol_lender="0.30"
min_pol_borrower="0.30"
min_pol_deployer="0.30"
min_tusd_lender="500"
min_tusd_borrower="50"
deployments="$DEFAULT_DEPLOYMENTS"
evidence=""
allow_late=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --allow-late)
      allow_late=1
      shift
      ;;
    --gate | --gate-at | --now | --lender | --borrower | --deployer | --min-pol-lender | \
      --min-pol-borrower | --min-pol-deployer | --min-tusd-lender | --min-tusd-borrower | \
      --deployments | --evidence)
      need_value "$1" "$#" "${2:-}"
      case "$1" in
        --gate) gate="$2" ;;
        --gate-at) gate_at="$2" ;;
        --now) now_arg="$2" ;;
        --lender) lender="$2" ;;
        --borrower) borrower="$2" ;;
        --deployer) deployer="$2" ;;
        --min-pol-lender) min_pol_lender="$2" ;;
        --min-pol-borrower) min_pol_borrower="$2" ;;
        --min-pol-deployer) min_pol_deployer="$2" ;;
        --min-tusd-lender) min_tusd_lender="$2" ;;
        --min-tusd-borrower) min_tusd_borrower="$2" ;;
        --deployments) deployments="$2" ;;
        --evidence) evidence="$2" ;;
      esac
      shift 2
      ;;
    *) die 2 "unknown argument '$1' (usage: funding-check.sh --gate NAME --gate-at ISO [options])" ;;
  esac
done

# ---------------------------------------------------------------- validation (exit 2)

[ -n "$gate" ] || die 2 "missing --gate"
[ -n "$gate_at" ] || die 2 "missing --gate-at"
is_safe_name "$gate" || die 2 "--gate may only hold letters, digits, dot, underscore and hyphen"
gate_epoch="$(iso_to_epoch "$gate_at")" || die 2 "--gate-at must be a UTC time like 2026-12-04T23:00:00Z"
if [ -n "$now_arg" ]; then
  checked_at="$now_arg"
  clock_overridden=true
else
  checked_at="$(now_iso)"
  clock_overridden=false
fi
now_epoch="$(iso_to_epoch "$checked_at")" || die 2 "--now must be a UTC time like 2026-12-03T17:00:00Z"
for a in "$lender" "$borrower" "$deployer"; do
  is_address "$a" || die 2 "not an address: $a"
done

wei_cap="100000000000000000000" # 100 POL: a minimum above this is a typing mistake
tusd_cap="100000000000000"      # 100,000,000 tokens
min_pol_lender_wei="$(pol_to_wei "$min_pol_lender")" || die 2 "bad --min-pol-lender '$min_pol_lender'"
min_pol_borrower_wei="$(pol_to_wei "$min_pol_borrower")" || die 2 "bad --min-pol-borrower '$min_pol_borrower'"
min_pol_deployer_wei="$(pol_to_wei "$min_pol_deployer")" || die 2 "bad --min-pol-deployer '$min_pol_deployer'"
min_tusd_lender_base="$(parse_token_amount "$min_tusd_lender")" || die 2 "bad --min-tusd-lender '$min_tusd_lender' (up to $TOKEN_DECIMALS decimals)"
min_tusd_borrower_base="$(parse_token_amount "$min_tusd_borrower")" || die 2 "bad --min-tusd-borrower '$min_tusd_borrower' (up to $TOKEN_DECIMALS decimals)"
for m in "$min_pol_lender_wei" "$min_pol_borrower_wei" "$min_pol_deployer_wei"; do
  wei_ge "$wei_cap" "$m" || die 2 "a POL minimum above 100 POL is not plausible"
done
for m in "$min_tusd_lender_base" "$min_tusd_borrower_base"; do
  wei_ge "$tusd_cap" "$m" || die 2 "a tUSD minimum above 100000000 tokens is not plausible"
done

if [ -z "$evidence" ]; then
  stamp="${checked_at//[-:]/}"
  evidence="${GATE_EVIDENCE_DIR:-$GATE_REPO_ROOT/broadcast}/gate-${gate}-${stamp}.json"
fi

# ---------------------------------------------------------------- chain reads (exit 3)

token="$(read_token_address "$deployments")"
require_amoy

block="$(cast block-number 2>/dev/null)" || die 3 "could not read the block number from $(url_host "$AMOY_RPC_URL")"
case "$block" in '' | *[!0-9]*) die 3 "unexpected block number answer" ;; esac

any_short=0
objects=""
printf '%-9s %-44s %-12s %-14s %-14s %-14s %s\n' ROLE ADDRESS "POL" "TUSD" "MINTED" "HEADROOM" STATUS

# check_wallet ROLE ADDRESS MIN_POL_WEI MIN_TUSD_BASE
check_wallet() {
  local role="$1" addr="$2" min_pol="$3" min_tusd="$4"
  local pol tusd minted headroom short low_pol=0 low_tusd=0 status flags="" flags_json="[]"
  pol="$(cast balance "$addr" 2>/dev/null)" || die 3 "could not read the POL balance of $role"
  case "$pol" in '' | *[!0-9]*) die 3 "unexpected POL balance answer for $role" ;; esac
  tusd="$(cast_uint "$token" "balanceOf(address)(uint256)" "$addr")" || die 3 "could not read the tUSD balance of $role"
  minted="$(cast_uint "$token" "mintedTo(address)(uint256)" "$addr")" || die 3 "could not read mintedTo of $role"
  pol="$(wei_norm "$pol")"
  tusd="$(wei_norm "$tusd")"
  minted="$(wei_norm "$minted")"

  if wei_ge "$MINT_ADDRESS_CAP_BASE" "$minted"; then
    headroom=$((MINT_ADDRESS_CAP_BASE - minted))
  else
    headroom=0
  fi

  wei_ge "$pol" "$min_pol" || low_pol=1
  wei_ge "$tusd" "$min_tusd" || low_tusd=1
  if [ "$low_pol" -eq 1 ] && [ "$low_tusd" -eq 1 ]; then
    status=LOW_BOTH
  elif [ "$low_pol" -eq 1 ]; then
    status=LOW_POL
  elif [ "$low_tusd" -eq 1 ]; then
    status=LOW_TUSD
  else
    status=OK
  fi
  # A balance below the minimum is a small number, so this subtraction cannot overflow.
  if [ "$low_tusd" -eq 1 ]; then
    short=$((min_tusd - tusd))
    if [ "$short" -gt "$headroom" ]; then
      flags="NO_MINT_HEADROOM"
      flags_json='["NO_MINT_HEADROOM"]'
    fi
  fi
  [ "$status" = OK ] || any_short=1

  printf '%-9s %-44s %-12s %-14s %-14s %-14s %s%s\n' "$role" "$addr" "$(wei_to_pol "$pol")" \
    "$(format_token "$tusd")" "$(format_token "$minted")" "$(format_token "$headroom")" "$status" "${flags:+ $flags}"

  objects="$objects$(jq -nc --arg role "$role" --arg address "$addr" --arg pol "$pol" \
    --arg tusd "$tusd" --arg minted "$minted" --arg headroom "$headroom" --arg status "$status" \
    --argjson flags "$flags_json" \
    '{role: $role, address: $address, polWei: $pol, tusdBase: $tusd, mintedToBase: $minted,
      mintHeadroomBase: $headroom, status: $status, flags: $flags}')
"
}

check_wallet lender "$lender" "$min_pol_lender_wei" "$min_tusd_lender_base"
check_wallet borrower "$borrower" "$min_pol_borrower_wei" "$min_tusd_borrower_base"
check_wallet deployer "$deployer" "$min_pol_deployer_wei" "0"

# ---------------------------------------------------------------- verdict

lead_seconds=$((gate_epoch - now_epoch))
lead_hours="$(floor_hours "$lead_seconds")"
early=false
[ "$lead_seconds" -ge "$QUALIFY_LEAD_SECONDS" ] && early=true

if [ "$any_short" -eq 1 ]; then
  result=SHORT
  qualifying=false
  rc=1
elif [ "$early" = true ]; then
  result=QUALIFYING
  qualifying=true
  rc=0
else
  result=NOT_QUALIFYING_LATE
  qualifying=false
  if [ "$allow_late" -eq 1 ]; then rc=0; else rc=4; fi
fi

echo
echo "gate: $gate at $gate_at"
echo "checked: $checked_at at block $block"
echo "lead: ${lead_hours}h before the gate"
[ "$clock_overridden" = false ] || echo "warning: --now overrides the clock, so this evidence is not valid for a gate"
case "$result" in
  QUALIFYING) echo "verdict: QUALIFYING (every wallet funded and at least 24 hours before the gate)" ;;
  SHORT) echo "verdict: SHORT (at least one wallet is below its minimum)" ;;
  *)
    if [ "$allow_late" -eq 1 ]; then
      echo "verdict: NOT QUALIFYING, funded but fewer than 24 hours before the gate (--allow-late given)"
    else
      echo "verdict: NOT QUALIFYING, funded but fewer than 24 hours before the gate"
    fi
    ;;
esac

doc="$(printf '%s' "$objects" | jq -s \
  --arg gate "$gate" --arg gateAt "$gate_at" --arg checkedAt "$checked_at" \
  --argjson leadHours "$lead_hours" --argjson qualifying "$qualifying" \
  --argjson chainId "$EXPECTED_CHAIN_ID" --argjson blockNumber "$block" --arg token "$token" \
  --argjson clockOverridden "$clock_overridden" --argjson allowLate "$([ "$allow_late" -eq 1 ] && echo true || echo false)" \
  --arg result "$result" \
  --arg mpl "$min_pol_lender_wei" --arg mpb "$min_pol_borrower_wei" --arg mpd "$min_pol_deployer_wei" \
  --arg mtl "$min_tusd_lender_base" --arg mtb "$min_tusd_borrower_base" \
  '{gate: $gate, gateAt: $gateAt, checkedAt: $checkedAt, leadHours: $leadHours,
    qualifying: $qualifying, result: $result, chainId: $chainId, blockNumber: $blockNumber,
    token: $token, clockOverridden: $clockOverridden, allowLate: $allowLate,
    minimums: {polWei: {lender: $mpl, borrower: $mpb, deployer: $mpd},
               tusdBase: {lender: $mtl, borrower: $mtb}},
    wallets: .}')"
write_evidence "$evidence" "$doc"
echo "evidence: $evidence"
exit "$rc"
