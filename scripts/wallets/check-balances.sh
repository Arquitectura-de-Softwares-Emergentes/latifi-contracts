#!/usr/bin/env bash
# Balance table for the demo wallet pool.
#   bash scripts/wallets/check-balances.sh          table of role, address, balance and status
#   bash scripts/wallets/check-balances.sh --json   JSON array with role, address, balancePol, status
# Exit codes: 0 every wallet is at or above its minimum, 1 at least one wallet is LOW,
#             2 bad usage or manifest, 3 the RPC is missing, unreachable or not chain id 80002.
# The RPC URL is never printed. Needs cast and jq. Compatible with bash 3.2.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

json=0
case "${1:-}" in
  '') ;;
  --json) json=1 ;;
  *) die 2 "usage: check-balances.sh [--json]" ;;
esac

require_manifest
require_amoy

any_low=0
objects=""
if [ "$json" -eq 0 ]; then
  printf '%-11s %-44s %-22s %s\n' ROLE ADDRESS "BALANCE (POL)" STATUS
fi

for role in $(manifest_roles); do
  addr="$(role_address "$role")"
  min_wei="$(pol_to_wei "$(role_min_pol "$role")")" || die 2 "bad minimum for role $role"
  bal_wei="$(cast balance "$addr" 2>/dev/null)" || die 3 "could not read the balance of $role"
  case "$bal_wei" in '' | *[!0-9]*) die 3 "unexpected balance answer for $role" ;; esac
  pol="$(wei_to_pol "$bal_wei")"
  if wei_ge "$bal_wei" "$min_wei"; then status=OK; else status=LOW; any_low=1; fi
  if [ "$json" -eq 1 ]; then
    objects="$objects$(jq -nc --arg r "$role" --arg a "$addr" --arg b "$pol" --arg s "$status" \
      '{role: $r, address: $a, balancePol: $b, status: $s}')
"
  else
    printf '%-11s %-44s %-22s %s\n' "$role" "$addr" "$pol" "$status"
  fi
done

if [ "$json" -eq 1 ]; then
  printf '%s' "$objects" | jq -s '.'
fi
exit "$any_low"
