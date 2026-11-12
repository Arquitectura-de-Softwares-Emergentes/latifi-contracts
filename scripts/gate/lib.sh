#!/usr/bin/env bash
# Shared helpers for the gate funding scripts. Source this file, do not execute it.
# Compatible with bash 3.2 (macOS) and bash 5 (Linux). Needs cast and jq.
#
# It reuses the guards of the wallet pool scripts (die, url_host, load_rpc, require_amoy, wei_ge,
# wei_add, pol_to_wei, wei_to_pol) by sourcing them. Nothing is copied.
#
# Rules enforced here (T-07-13, T-07-14, T-07-15):
#   - the RPC URL comes from the environment or ~/.latifi/rpc.env and reaches cast only through
#     ETH_RPC_URL, never as an argument, and is never printed or written to evidence;
#   - no function here reads, prints or forwards a password or a private key;
#   - every script calls a chain guard before the first cast call that matters.

GATE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../wallets/lib.sh
. "$GATE_LIB_DIR/../wallets/lib.sh"

GATE_REPO_ROOT="$(cd "$GATE_LIB_DIR/../.." && pwd)"
DEFAULT_DEPLOYMENTS="$GATE_REPO_ROOT/deployments/amoy.json"

# Public demo addresses (the same ones scripts/cycle.sh and docs/DEPLOY-AMOY.md name).
DEMO_DEPLOYER="0x5577fc66c64e4749eed2e09E6Cd5A2b0e7F970D6"
DEMO_LENDER="0xA22412ba83539ACFd3385DA78F6214E800E865a3"
DEMO_BORROWER="0xcb9003E7f369AE9b55C18D8cfEC8A32a12ee61F0"

# MockStablecoin facts (src/MockStablecoin.sol): 6 decimals, 10,000 tokens per mintTo call and
# 10,000 tokens cumulative per address.
TOKEN_DECIMALS=6
MINT_CALL_CAP_BASE="10000000000"
MINT_ADDRESS_CAP_BASE="10000000000"

# A run qualifies only when it happens at least this long before the gate.
QUALIFY_LEAD_SECONDS=86400

# Amoy gas flags, the same as scripts/cycle.sh.
AMOY_GAS_FLAGS="--gas-price 35gwei --priority-gas-price 30gwei"

# ---------------------------------------------------------------- argument checks

# Dies with exit 2 unless the value is usable after a flag: present and not another flag.
need_value() { # flag, remaining argument count, next value
  [ "$2" -ge 2 ] || die 2 "$1 needs a value"
  case "$3" in -*) die 2 "$1 needs a value, got '$3'" ;; esac
}

is_address() {
  case "$1" in
    0x????????????????????????????????????????) ;;
    *) return 1 ;;
  esac
  printf '%s' "${1#0x}" | grep -Eq '^[0-9a-fA-F]{40}$'
}

# A free text name that is safe inside a file name and never looks like a flag.
is_safe_name() {
  printf '%s' "$1" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$'
}

# ---------------------------------------------------------------- dates

# Prints the Unix epoch of a UTC timestamp written as YYYY-MM-DDTHH:MM:SSZ. Pure bash integer
# arithmetic (civil date algorithm), so it needs neither `date -d` (GNU) nor `date -j` (BSD) and
# macOS and Linux agree. Returns 1 on any malformed or impossible date. Years 1970 to 2999.
iso_to_epoch() {
  local s="$1"
  local re='^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})Z$'
  [[ "$s" =~ $re ]] || return 1
  local y mo d h mi se
  y=$((10#${BASH_REMATCH[1]}))
  mo=$((10#${BASH_REMATCH[2]}))
  d=$((10#${BASH_REMATCH[3]}))
  h=$((10#${BASH_REMATCH[4]}))
  mi=$((10#${BASH_REMATCH[5]}))
  se=$((10#${BASH_REMATCH[6]}))
  [ "$y" -ge 1970 ] && [ "$mo" -ge 1 ] && [ "$mo" -le 12 ] || return 1
  [ "$h" -le 23 ] && [ "$mi" -le 59 ] && [ "$se" -le 59 ] || return 1
  local dim
  case "$mo" in
    1 | 3 | 5 | 7 | 8 | 10 | 12) dim=31 ;;
    4 | 6 | 9 | 11) dim=30 ;;
    *)
      if { [ $((y % 4)) -eq 0 ] && [ $((y % 100)) -ne 0 ]; } || [ $((y % 400)) -eq 0 ]; then
        dim=29
      else
        dim=28
      fi
      ;;
  esac
  [ "$d" -ge 1 ] && [ "$d" -le "$dim" ] || return 1
  # Days since 1970-01-01. The year starts in March so the leap day is the last day of the year.
  local yy="$y" mp era yoe doy doe days
  [ "$mo" -le 2 ] && yy=$((yy - 1))
  era=$((yy / 400))
  yoe=$((yy - era * 400))
  if [ "$mo" -gt 2 ]; then mp=$((mo - 3)); else mp=$((mo + 9)); fi
  doy=$(((153 * mp + 2) / 5 + d - 1))
  doe=$((yoe * 365 + yoe / 4 - yoe / 100 + doy))
  days=$((era * 146097 + doe - 719468))
  printf '%s\n' $((days * 86400 + h * 3600 + mi * 60 + se))
}

# The current time as YYYY-MM-DDTHH:MM:SSZ. `date -u +FORMAT` is the same on macOS and Linux.
now_iso() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# Integer hours of a signed number of seconds, rounded toward minus infinity, so 23h59m is 23.
floor_hours() {
  local s="$1"
  if [ "$s" -ge 0 ]; then
    printf '%s\n' $((s / 3600))
  else
    printf '%s\n' $((-((-s + 3599) / 3600)))
  fi
}

# ---------------------------------------------------------------- amounts

# Converts a decimal token amount such as 12.5 to base units (6 decimals) in integer arithmetic.
# Refuses more than 6 fractional digits, a sign, an exponent and an empty part. Returns 1 on error.
parse_token_amount() {
  local v="$1" int frac
  case "$v" in
    '' | *[!0-9.]* | .* | *. | *.*.*) return 1 ;;
  esac
  int="${v%%.*}"
  if [ "$int" = "$v" ]; then frac=""; else frac="${v#*.}"; fi
  [ "${#frac}" -le "$TOKEN_DECIMALS" ] || return 1
  while [ "${#frac}" -lt "$TOKEN_DECIMALS" ]; do frac="${frac}0"; done
  wei_norm "${int}${frac}"
}

# Converts base units to a decimal token string without trailing zeros (one decimal at least).
format_token() {
  local w
  w="$(wei_norm "$1")"
  while [ "${#w}" -le "$TOKEN_DECIMALS" ]; do w="0$w"; done
  local int="${w:0:$((${#w} - TOKEN_DECIMALS))}" frac="${w:$((${#w} - TOKEN_DECIMALS))}"
  frac="${frac%"${frac##*[!0]}"}"
  printf '%s.%s\n' "$int" "${frac:-0}"
}

# ---------------------------------------------------------------- cast output

# Prints the first whitespace separated token of the first line. `cast call` answers such as
# "1000000 [1e6]" carry a bracketed annotation after the number.
first_token() {
  awk 'NR == 1 { print $1 }'
}

# Runs `cast call ARGS` (the RPC comes from ETH_RPC_URL) and prints the unsigned integer answer.
# Returns 1 when the call fails or the answer is not a plain unsigned integer.
cast_uint() {
  local out v
  out="$(cast call "$@" 2>/dev/null)" || return 1
  v="$(printf '%s\n' "$out" | first_token)"
  case "$v" in '' | *[!0-9]*) return 1 ;; esac
  printf '%s\n' "$v"
}

# Removes anything shaped like a URL from text read on stdin, so cast error output can be shown
# without ever echoing the RPC endpoint and its key.
scrub_urls() {
  sed -E 's#[A-Za-z][A-Za-z0-9+.-]*://[^[:space:])"'"'"']*#<url>#g'
}

# ---------------------------------------------------------------- chain guards

# Strict chain guard for scripts that can send. Exit 3 when the RPC is missing or unreachable and
# exit 2 when it answers a chain other than 80002. Never prints the URL, only its host.
require_amoy_strict() {
  load_rpc
  local id
  if ! id="$(cast chain-id 2>/dev/null)"; then
    die 3 "could not read the chain id from $(url_host "$AMOY_RPC_URL")"
  fi
  if [ "$id" != "$EXPECTED_CHAIN_ID" ]; then
    die 2 "wrong network: $(url_host "$AMOY_RPC_URL") reports chain id '$id', expected $EXPECTED_CHAIN_ID"
  fi
}

# ---------------------------------------------------------------- deployments

# Prints the MockStablecoin address of a deployments file after checking its chain id.
read_token_address() {
  local file="$1" addr
  [ -f "$file" ] || die 2 "deployments file not found: $file"
  jq -e --argjson id "$EXPECTED_CHAIN_ID" '.chainId == $id' "$file" >/dev/null 2>&1 ||
    die 2 "deployments file is invalid or not for chain id $EXPECTED_CHAIN_ID: $file"
  addr="$(jq -r '.contracts.MockStablecoin.address // empty' "$file")"
  is_address "$addr" || die 2 "no valid MockStablecoin address in $file"
  printf '%s\n' "$addr"
}

# ---------------------------------------------------------------- evidence

# Writes a JSON document atomically after checking that it parses. The caller builds it with jq.
write_evidence() { # file, json text
  local file="$1" json="$2" dir tmp
  printf '%s' "$json" | jq -e . >/dev/null 2>&1 || die 2 "internal error: evidence is not valid JSON"
  dir="$(dirname "$file")"
  mkdir -p "$dir" || die 2 "cannot create $dir"
  tmp="$(mktemp "$dir/.gate-evidence.XXXXXX")" || die 2 "cannot write in $dir"
  printf '%s\n' "$json" | jq . >"$tmp"
  chmod 644 "$tmp"
  mv "$tmp" "$file"
}
