#!/usr/bin/env bash
# Shared helpers for the demo wallet pool scripts. Source this file, do not execute it.
# Compatible with bash 3.2. Needs cast and jq.
#
# Rules enforced here (TC-01, T-07-01, T-07-04):
#   - every script that touches the network calls require_amoy first and exits 3 unless the RPC
#     reports chain id 80002;
#   - the RPC URL is read from the environment or from ~/.latifi/rpc.env, handed to cast through
#     ETH_RPC_URL (never as a command line argument) and never printed. Errors name the host only.

EXPECTED_CHAIN_ID=80002
WALLETS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$WALLETS_LIB_DIR/../.." && pwd)"
MANIFEST="${DEMO_WALLETS_MANIFEST:-$REPO_ROOT/deployments/demo-wallets.json}"
LATIFI_HOME="${LATIFI_HOME:-$HOME/.latifi}"

die() {
  local code="$1"
  shift
  echo "error: $*" >&2
  exit "$code"
}

# Prints only the host part of a URL, so an error can name the endpoint without leaking the key.
url_host() {
  printf '%s' "$1" | sed -E 's#^[A-Za-z][A-Za-z0-9+.-]*://##; s#^[^@/]*@##; s#[/?#:].*$##'
}

# Loads AMOY_RPC_URL from ~/.latifi/rpc.env only when it is not already set. The file is parsed,
# not sourced, so nothing in it is ever executed.
load_rpc() {
  if [ -z "${AMOY_RPC_URL:-}" ] && [ -f "$LATIFI_HOME/rpc.env" ]; then
    AMOY_RPC_URL="$(grep -E '^AMOY_RPC_URL=' "$LATIFI_HOME/rpc.env" | head -n 1 | cut -d= -f2-)"
  fi
  if [ -z "${AMOY_RPC_URL:-}" ]; then
    die 3 "AMOY_RPC_URL is not set and $LATIFI_HOME/rpc.env does not define it"
  fi
  export AMOY_RPC_URL
  export ETH_RPC_URL="$AMOY_RPC_URL"
}

# Chain id guard. Exits 3 unless the endpoint answers 80002.
require_amoy() {
  load_rpc
  local id
  if ! id="$(cast chain-id 2>/dev/null)"; then
    die 3 "could not read the chain id from $(url_host "$AMOY_RPC_URL")"
  fi
  if [ "$id" != "$EXPECTED_CHAIN_ID" ]; then
    die 3 "wrong network: $(url_host "$AMOY_RPC_URL") reports chain id '$id', expected $EXPECTED_CHAIN_ID"
  fi
}

# Manifest helpers. The manifest holds public data only (roles, addresses, minimums).
require_manifest() {
  [ -f "$MANIFEST" ] || die 2 "manifest not found: $MANIFEST (run scripts/wallets/new-pool.sh first)"
  jq -e --argjson id "$EXPECTED_CHAIN_ID" \
    '.chainId == $id and (.wallets | type == "array" and length > 0)' "$MANIFEST" >/dev/null 2>&1 ||
    die 2 "manifest is invalid or not for chain id $EXPECTED_CHAIN_ID: $MANIFEST"
}

manifest_roles() {
  jq -r '.wallets[].role' "$MANIFEST"
}

role_address() {
  local addr
  addr="$(jq -r --arg r "$1" '.wallets[] | select(.role == $r) | .address' "$MANIFEST")"
  [ -n "$addr" ] || die 2 "unknown role: $1"
  case "$addr" in
    0x????????????????????????????????????????) ;;
    *) die 2 "bad address for role $1" ;;
  esac
  printf '%s\n' "$addr"
}

role_min_pol() {
  jq -r --arg r "$1" '(.minBalancePol[$r] // .minBalancePol.default)' "$MANIFEST"
}

# Exact integer arithmetic on wei values held as decimal strings.
# Strips leading zeros.
wei_norm() {
  local v="${1#"${1%%[!0]*}"}"
  printf '%s\n' "${v:-0}"
}

# Returns 0 when A >= B. Compares digit length first, then lexicographically. No floating point.
wei_ge() {
  local a b
  a="$(wei_norm "$1")"
  b="$(wei_norm "$2")"
  if [ "${#a}" -ne "${#b}" ]; then
    [ "${#a}" -gt "${#b}" ]
    return
  fi
  [ "$a" = "$b" ] || [ "$(LC_ALL=C; [[ "$a" > "$b" ]] && echo gt)" = "gt" ]
}

# Adds two non-negative wei values (digit by digit, bash 3.2 safe, no overflow for realistic sizes).
wei_add() {
  local a b
  a="$(wei_norm "$1")"
  b="$(wei_norm "$2")"
  while [ "${#a}" -lt "${#b}" ]; do a="0$a"; done
  while [ "${#b}" -lt "${#a}" ]; do b="0$b"; done
  local i carry=0 out="" da db s
  i=$((${#a} - 1))
  while [ "$i" -ge 0 ]; do
    da="${a:$i:1}"
    db="${b:$i:1}"
    s=$((da + db + carry))
    out="$((s % 10))$out"
    carry=$((s / 10))
    i=$((i - 1))
  done
  [ "$carry" -eq 0 ] || out="$carry$out"
  wei_norm "$out"
}

# Converts a decimal POL amount such as 0.3 or 1 to wei, in pure integer arithmetic.
# Accepts up to 18 decimals. Prints nothing and returns 1 on a malformed amount.
pol_to_wei() {
  local v="$1" int frac
  case "$v" in
    '' | *[!0-9.]* | .* | *. | *.*.*) return 1 ;;
  esac
  int="${v%%.*}"
  if [ "$int" = "$v" ]; then frac=""; else frac="${v#*.}"; fi
  [ "${#frac}" -le 18 ] || return 1
  while [ "${#frac}" -lt 18 ]; do frac="${frac}0"; done
  wei_norm "${int}${frac}"
}

# Converts wei to a POL string without trailing zeros (at least one decimal digit).
wei_to_pol() {
  local w
  w="$(wei_norm "$1")"
  while [ "${#w}" -le 18 ]; do w="0$w"; done
  local int="${w:0:$((${#w} - 18))}" frac="${w:$((${#w} - 18))}"
  frac="${frac%"${frac##*[!0]}"}"
  printf '%s.%s\n' "$int" "${frac:-0}"
}
