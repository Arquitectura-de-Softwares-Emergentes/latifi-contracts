#!/usr/bin/env bash
# Offline tests for the gate funding scripts (lib.sh, funding-check.sh, top-up.sh).
# A stub `cast` stands in for the network, so the suite needs no RPC, no keys and no funds.
# Run from anywhere. Needs jq. Compatible with bash 3.2.
# Prints `gate-test: ok N cases` and exits 0, or prints the failing case and exits 1 at once.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CANARY="https://rpc.example.invalid/v2/CANARYKEYCANARYKEY0123456789"
PWCANARY="PWCANARY-never-print-this"
ST="$WORK/state"
mkdir -p "$WORK/bin" "$ST/pol" "$ST/tusd" "$ST/minted" "$ST/accounts" "$WORK/home"

# ---------------------------------------------------------------- stub cast
# Answers chain-id, balance, block-number, call (by signature), wallet address and send.
# Logs every call. Fails the suite on a leaked RPC URL, a raw key or a password argument.
cat >"$WORK/bin/cast" <<'STUB'
#!/usr/bin/env bash
echo "cast $*" >>"$STUB_LOG"
lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
case "$*" in *rpc.example.invalid*) echo "stub: rpc url leaked into argv" >&2; exit 9 ;; esac
case "$*" in *--private-key* | *--mnemonic* | *--password\ * | *--unlocked*)
  echo "stub: a raw key or password argument was passed" >&2; exit 9 ;; esac
case "$*" in *PWCANARY*) echo "stub: a password was passed on the command line" >&2; exit 9 ;; esac
case "$1" in chain-id | balance | block-number | call | send)
  [ -n "${ETH_RPC_URL:-}" ] || { echo "stub: ETH_RPC_URL missing" >&2; exit 9; } ;;
esac
annotate() { # prints "V [1e6]" like cast does for big numbers
  local v="$1"
  if [ "${#v}" -gt 4 ]; then echo "$v [${v:0:1}e$((${#v} - 1))]"; else echo "$v"; fi
}
ROLE="${STUB_ROLE:-0x9f2df0fed2c77648de5860a4cc508cd0818c85b8b8a1ab4ceeef8d981c8956a6}"
case "$1" in
  chain-id)
    [ -z "${STUB_RPC_DOWN:-}" ] || { echo "connection refused for $ETH_RPC_URL" >&2; exit 1; }
    echo "${STUB_NETWORK:-80002}" ;;
  block-number) echo 12345678 ;;
  balance) cat "$STUB_STATE/pol/$(lc "$2")" ;;
  call)
    [ -z "${STUB_CALL_FAIL:-}" ] || { echo "execution reverted at $ETH_RPC_URL" >&2; exit 1; }
    case "$3" in
      'balanceOf(address)(uint256)') annotate "$(cat "$STUB_STATE/tusd/$(lc "$4")")" ;;
      'mintedTo(address)(uint256)') annotate "$(cat "$STUB_STATE/minted/$(lc "$4")")" ;;
      'MINTER_ROLE()(bytes32)') echo "$ROLE" ;;
      'hasRole(bytes32,address)(bool)')
        if [ "$4" = "$ROLE" ] && grep -qx "$(lc "$5")" "$STUB_STATE/minters" 2>/dev/null; then echo true; else echo false; fi ;;
      *) echo "stub: unknown call $3" >&2; exit 8 ;;
    esac ;;
  wallet)
    [ "$2" = address ] || exit 8
    name=""
    prev=""
    for a in "$@"; do
      case "$prev" in --account | --keystore) name="$(basename "$a")" ;; esac
      prev="$a"
    done
    [ -f "$STUB_STATE/accounts/$name" ] || { echo "stub: no such account" >&2; exit 1; }
    cat "$STUB_STATE/accounts/$name" ;;
  send)
    re='^0x[0-9a-fA-F]{64}$'
    for a in "$@"; do
      if [[ "$a" =~ $re ]]; then echo "stub: a raw 32 byte value was passed to send" >&2; exit 9; fi
    done
    [ -z "${STUB_SEND_FAIL:-}" ] || { echo "error sending request for url ($ETH_RPC_URL)" >&2; exit 1; }
    status="${STUB_SEND_STATUS:-0x1}"
    if [ "$status" = 0x1 ]; then
      if [ "$3" = "mintTo(address,uint256)" ]; then
        to="$(lc "$4")"
        echo $(($(cat "$STUB_STATE/tusd/$to") + $5)) >"$STUB_STATE/tusd/$to"
        echo $(($(cat "$STUB_STATE/minted/$to") + $5)) >"$STUB_STATE/minted/$to"
      else
        to="$(lc "$2")"
        echo $(($(cat "$STUB_STATE/pol/$to") + $4)) >"$STUB_STATE/pol/$to"
      fi
    fi
    printf '{"transactionHash":"0xabc123","status":"%s","blockNumber":"0x10"}\n' "$status" ;;
  *) exit 8 ;;
esac
STUB
chmod +x "$WORK/bin/cast"

export PATH="$WORK/bin:$PATH"
export STUB_LOG="$WORK/calls.log"
export STUB_STATE="$ST"
export LATIFI_HOME="$WORK/home/.latifi"
export AMOY_RPC_URL="$CANARY"
export GATE_EVIDENCE_DIR="$WORK/broadcast"
: >"$STUB_LOG"

# ---------------------------------------------------------------- harness

CASES=0
fail() {
  echo "gate-test: FAIL $1" >&2
  [ -z "${OUT:-}" ] || printf '%s\n' "$OUT" | sed 's/^/  | /' >&2
  exit 1
}
exit_is() { # name, expected exit
  CASES=$((CASES + 1))
  [ "$RC" = "$2" ] || fail "$1 (expected exit $2, got $RC)"
}
holds() { # name, command words that must succeed
  CASES=$((CASES + 1))
  local name="$1"
  shift
  "$@" >/dev/null 2>&1 || fail "$name"
}
eq() { # name, expected, actual
  CASES=$((CASES + 1))
  [ "$2" = "$3" ] || fail "$1 (expected '$2', got '$3')"
}
run() {
  OUT="$("$@" 2>&1)"
  RC=$?
}
has() { printf '%s' "$OUT" | grep -qF -- "$1"; }
not_has() { ! printf '%s' "$OUT" | grep -qF -- "$1"; }
no_code_match() { # pattern, files: no match outside comment lines
  ! (grep -hv '^[[:space:]]*#' "${@:2}" | grep -Eq "$1")
}
logged() { grep -qF -- "$1" "$STUB_LOG"; }
not_logged() { ! grep -qF -- "$1" "$STUB_LOG"; }

# shellcheck source=lib.sh
. "$HERE/lib.sh"

DEPLOY="$WORK/amoy.json"
TOKEN_ADDR="0x66757f1Cc66B278BfC0eeFad7e3Cac1d70fd4f8B"
printf '{"chainId":80002,"deployer":"%s","contracts":{"MockStablecoin":{"address":"%s"}}}\n' \
  "$DEMO_DEPLOYER" "$TOKEN_ADDR" >"$DEPLOY"

LENDER="$DEMO_LENDER"
BORROWER="$DEMO_BORROWER"
DEPLOYER="$DEMO_DEPLOYER"
lcase() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
setw() { # address, pol wei, tusd base, minted base
  local a
  a="$(lcase "$1")"
  printf '%s' "$2" >"$ST/pol/$a"
  printf '%s' "$3" >"$ST/tusd/$a"
  printf '%s' "$4" >"$ST/minted/$a"
}
funded() {
  setw "$LENDER" 500000000000000000 600000000 600000000
  setw "$BORROWER" 500000000000000000 60000000 60000000
  setw "$DEPLOYER" 2000000000000000000 0 0
}
funded

GATE_AT="2026-12-04T23:00:00Z"
NOW_OK="2026-12-03T17:00:00Z" # 30 hours before the gate
EV="$WORK/evidence.json"
FC() {
  rm -f "$EV"
  run bash "$HERE/funding-check.sh" --gate TB2 --gate-at "$GATE_AT" --now "$NOW_OK" \
    --deployments "$DEPLOY" --evidence "$EV" "$@"
}
ev() { jq -r "$1" "$EV"; }

# ---------------------------------------------------------------- 1. lib: dates

eq "epoch of 1970-01-01" 0 "$(iso_to_epoch 1970-01-01T00:00:00Z)"
eq "epoch of a leap day" 1709164800 "$(iso_to_epoch 2024-02-29T00:00:00Z)"
eq "epoch of the day after a leap day" 1709251200 "$(iso_to_epoch 2024-03-01T00:00:00Z)"
eq "a leap day is exactly 86400 seconds long" 86400 "$(($(iso_to_epoch 2024-03-01T00:00:00Z) - $(iso_to_epoch 2024-02-29T00:00:00Z)))"
eq "epoch of 2000-02-29 (divisible by 400)" 951825600 "$(iso_to_epoch 2000-02-29T12:00:00Z)"
eq "last second of a year" 1704067199 "$(iso_to_epoch 2023-12-31T23:59:59Z)"
eq "first second of the next year" 1704067200 "$(iso_to_epoch 2024-01-01T00:00:00Z)"
eq "a year boundary is one second apart" 1 "$(($(iso_to_epoch 2024-01-01T00:00:00Z) - $(iso_to_epoch 2023-12-31T23:59:59Z)))"
eq "a month boundary (30 to 31 days)" 86400 "$(($(iso_to_epoch 2026-12-01T00:00:00Z) - $(iso_to_epoch 2026-11-30T00:00:00Z)))"
eq "epoch of the first gate fixture" 1796425200 "$(iso_to_epoch 2026-12-04T23:00:00Z)"
eq "past 2038" 2147483648 "$(iso_to_epoch 2038-01-19T03:14:08Z)"
eq "end of 2099" 4102444799 "$(iso_to_epoch 2099-12-31T23:59:59Z)"
for bad in 2023-02-29T00:00:00Z 2100-02-29T00:00:00Z 2026-13-01T00:00:00Z 2026-00-10T00:00:00Z \
  2026-04-31T00:00:00Z 2026-12-04T24:00:00Z 2026-12-04T23:60:00Z 2026-12-04T23:00:60Z \
  2026-12-04T23:00:00 "2026-12-04 23:00:00Z" 2026-12-04 1969-12-31T23:59:59Z ""; do
  CASES=$((CASES + 1))
  if iso_to_epoch "$bad" >/dev/null 2>&1; then fail "iso_to_epoch accepted '$bad'"; fi
done
eq "leading zero month 08 is not octal" 1785542400 "$(iso_to_epoch 2026-08-01T00:00:00Z)"
eq "floor_hours 0" 0 "$(floor_hours 0)"
eq "floor_hours 86399 is 23" 23 "$(floor_hours 86399)"
eq "floor_hours 86400 is 24" 24 "$(floor_hours 86400)"
eq "floor_hours -1 is -1" -1 "$(floor_hours -1)"
eq "floor_hours -3600 is -1" -1 "$(floor_hours -3600)"
eq "floor_hours -3601 is -2" -2 "$(floor_hours -3601)"
holds "now_iso has the ISO shape" bash -c "printf '%s' '$(now_iso)' | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\$'"
holds "the date code avoids date -d and date -j" no_code_match 'date +-(d|j)' "$HERE/lib.sh" "$HERE/funding-check.sh" "$HERE/top-up.sh"

# ---------------------------------------------------------------- 2. lib: amounts and cast output

eq "parse 12.5" 12500000 "$(parse_token_amount 12.5)"
eq "parse 500" 500000000 "$(parse_token_amount 500)"
eq "parse 0.000001 is one base unit" 1 "$(parse_token_amount 0.000001)"
eq "parse leading zeros" 7000000 "$(parse_token_amount 007)"
eq "parse 6 decimals" 1234567 "$(parse_token_amount 1.234567)"
for bad in 0.0000001 .5 5. -1 1e3 1.2.3 "" abc "1 000"; do
  CASES=$((CASES + 1))
  if parse_token_amount "$bad" >/dev/null 2>&1; then fail "parse_token_amount accepted '$bad'"; fi
done
eq "format 12500000" 12.5 "$(format_token 12500000)"
eq "format 1" 0.000001 "$(format_token 1)"
eq "format 0" 0.0 "$(format_token 0)"
eq "format 10000 tokens" 10000.0 "$(format_token 10000000000)"
eq "first_token drops the annotation" 1000000 "$(printf '1000000 [1e6]\n' | first_token)"
eq "first_token plain" 42 "$(printf '42\n' | first_token)"
eq "scrub_urls removes a URL and its key" "failed at <url> now" "$(printf 'failed at %s now\n' "$CANARY" | scrub_urls)"
eq "scrub_urls keeps plain text" "no url here" "$(printf 'no url here\n' | scrub_urls)"

# ---------------------------------------------------------------- 3. funding-check: the 24 hour rule

FC
exit_is "funded 30 hours ahead qualifies" 0
eq "evidence qualifying true" true "$(ev .qualifying)"
eq "evidence result QUALIFYING" QUALIFYING "$(ev .result)"
eq "evidence lead hours 30" 30 "$(ev .leadHours)"
eq "evidence chain id" 80002 "$(ev .chainId)"
eq "evidence block number" 12345678 "$(ev .blockNumber)"
eq "evidence names the token" "$TOKEN_ADDR" "$(ev .token)"
eq "evidence has three wallets" 3 "$(ev '.wallets | length')"
eq "evidence wallet roles" "lender,borrower,deployer" "$(ev '[.wallets[].role] | join(",")')"
eq "--now is recorded as a clock override" true "$(ev .clockOverridden)"
holds "output has the lead line" has "lead: 30h before the gate"
holds "output has the QUALIFYING verdict" has "verdict: QUALIFYING"
eq "output has an OK row per wallet" 3 "$(printf '%s\n' "$OUT" | grep -c ' OK$')"

FC --now 2026-12-03T23:00:00Z
exit_is "exactly 24 hours ahead qualifies" 0
eq "exactly 24 hours: qualifying true" true "$(ev .qualifying)"
eq "exactly 24 hours: lead hours" 24 "$(ev .leadHours)"

FC --now 2026-12-03T23:00:01Z
exit_is "24 hours minus one second does not qualify" 4
eq "one second late: qualifying false" false "$(ev .qualifying)"
eq "one second late: lead hours floors to 23" 23 "$(ev .leadHours)"
eq "one second late: result" NOT_QUALIFYING_LATE "$(ev .result)"

FC --now 2026-12-03T23:01:00Z
exit_is "23h59m ahead does not qualify" 4
eq "23h59m: qualifying false" false "$(ev .qualifying)"
holds "23h59m: output says not qualifying" has "verdict: NOT QUALIFYING"

FC --now 2026-12-03T23:01:00Z --allow-late
exit_is "23h59m with --allow-late exits 0" 0
eq "--allow-late never yields qualifying true" false "$(ev .qualifying)"
eq "--allow-late records the flag" true "$(ev .allowLate)"
eq "--allow-late result" NOT_QUALIFYING_LATE "$(ev .result)"

FC --now 2026-12-05T01:00:00Z
exit_is "after the gate does not qualify" 4
eq "after the gate: negative lead hours" -2 "$(ev .leadHours)"
holds "after the gate: output shows a negative lead" has "lead: -2h before the gate"

FC --now 2026-12-05T01:00:00Z --allow-late
exit_is "after the gate with --allow-late exits 0" 0
eq "after the gate with --allow-late is still not qualifying" false "$(ev .qualifying)"

# leap day and year boundary through the whole script
FC --gate-at 2024-03-01T12:00:00Z --now 2024-02-28T11:59:59Z
exit_is "across a leap day: 48h00m01s ahead qualifies" 0
eq "across a leap day: lead hours" 48 "$(ev .leadHours)"
FC --gate-at 2024-01-01T10:00:00Z --now 2023-12-31T10:00:01Z
exit_is "across a year boundary: 23h59m59s ahead does not qualify" 4
eq "across a year boundary: lead hours" 23 "$(ev .leadHours)"

# ---------------------------------------------------------------- 4. funding-check: statuses and boundaries

setw "$LENDER" 100000000000000000 600000000 600000000
FC
exit_is "low POL wallet exits 1" 1
eq "low POL status" LOW_POL "$(ev '.wallets[] | select(.role=="lender") | .status')"
eq "low POL: qualifying false" false "$(ev .qualifying)"
eq "low POL: result SHORT" SHORT "$(ev .result)"
holds "low POL: table row names LOW_POL" has LOW_POL
FC --now 2026-12-05T01:00:00Z --allow-late
exit_is "a short wallet is never masked by --allow-late" 1
funded

setw "$BORROWER" 500000000000000000 10000000 10000000
FC
exit_is "low tUSD wallet exits 1" 1
eq "low tUSD status" LOW_TUSD "$(ev '.wallets[] | select(.role=="borrower") | .status')"
funded

setw "$BORROWER" 1 1 1
FC
exit_is "a wallet short of both exits 1" 1
eq "both short status" LOW_BOTH "$(ev '.wallets[] | select(.role=="borrower") | .status')"
funded

setw "$DEPLOYER" 100000000000000000 0 0
FC
exit_is "low deployer POL exits 1" 1
eq "deployer low POL status" LOW_POL "$(ev '.wallets[] | select(.role=="deployer") | .status')"
funded

FC
eq "the deployer needs no tUSD" OK "$(ev '.wallets[] | select(.role=="deployer") | .status')"

# NO_MINT_HEADROOM: shortfall 400 tokens against a headroom of 100 tokens
setw "$LENDER" 500000000000000000 100000000 9900000000
FC
exit_is "no mint headroom exits 1" 1
eq "no headroom flag" NO_MINT_HEADROOM "$(ev '.wallets[] | select(.role=="lender") | .flags[0]')"
eq "no headroom keeps the LOW_TUSD status" LOW_TUSD "$(ev '.wallets[] | select(.role=="lender") | .status')"
holds "no headroom shows in the table" has NO_MINT_HEADROOM
eq "headroom value in evidence" 100000000 "$(ev '.wallets[] | select(.role=="lender") | .mintHeadroomBase')"
# headroom exactly equal to the shortfall can still be minted
setw "$LENDER" 500000000000000000 100000000 9600000000
FC
eq "headroom equal to the shortfall has no flag" 0 "$(ev '.wallets[] | select(.role=="lender") | .flags | length')"
# mintedTo at the cap
setw "$LENDER" 500000000000000000 100000000 10000000000
FC
eq "minted at the cap leaves zero headroom" 0 "$(ev '.wallets[] | select(.role=="lender") | .mintHeadroomBase')"
eq "minted at the cap is flagged" NO_MINT_HEADROOM "$(ev '.wallets[] | select(.role=="lender") | .flags[0]')"
funded

# exact boundary values
setw "$LENDER" 300000000000000000 500000000 0
FC
exit_is "balances equal to the minimums are OK" 0
setw "$LENDER" 299999999999999999 500000000 0
FC
exit_is "one wei below the POL minimum is LOW" 1
eq "one wei below: status" LOW_POL "$(ev '.wallets[] | select(.role=="lender") | .status')"
setw "$LENDER" 300000000000000000 499999999 0
FC
exit_is "one base unit below the tUSD minimum is LOW" 1
eq "one base unit below: status" LOW_TUSD "$(ev '.wallets[] | select(.role=="lender") | .status')"
funded

# custom minimums
FC --min-pol-lender 0.6
exit_is "a custom POL minimum above the balance is LOW" 1
FC --min-tusd-borrower 60
exit_is "a custom tUSD minimum equal to the balance is OK" 0
FC --min-tusd-borrower 60.000001
exit_is "a custom tUSD minimum one unit above the balance is LOW" 1
funded

# a 29 digit balance
setw "$LENDER" 12345678901234567890123456789 12345678901234567890123456789 6000000
FC
exit_is "a 29 digit balance is compared exactly" 0
eq "a 29 digit POL balance is kept exactly" 12345678901234567890123456789 "$(ev '.wallets[] | select(.role=="lender") | .polWei')"
eq "a 29 digit tUSD balance is kept exactly" 12345678901234567890123456789 "$(ev '.wallets[] | select(.role=="lender") | .tusdBase')"
funded

# ---------------------------------------------------------------- 5. funding-check: network and usage

STUB_NETWORK=1 FC
exit_is "wrong chain exits 3" 3
holds "wrong chain message hides the key" not_has CANARYKEY
holds "wrong chain writes no evidence" bash -c "[ ! -e '$EV' ]"
STUB_NETWORK=137 FC
exit_is "chain 137 exits 3" 3
STUB_RPC_DOWN=1 FC
exit_is "a down RPC exits 3" 3
holds "down RPC message hides the key" not_has CANARYKEY
holds "down RPC message names the host" has rpc.example.invalid
STUB_CALL_FAIL=1 FC
exit_is "a failing token call exits 3" 3
holds "a failing token call hides the key" not_has CANARYKEY
AMOY_RPC_URL="" FC
exit_is "a missing RPC URL exits 3" 3

run bash "$HERE/funding-check.sh" --gate-at "$GATE_AT"
exit_is "missing --gate exits 2" 2
run bash "$HERE/funding-check.sh" --gate TB2
exit_is "missing --gate-at exits 2" 2
run bash "$HERE/funding-check.sh"
exit_is "no arguments exits 2" 2
FC --gate-at 2026-13-01T00:00:00Z
exit_is "an impossible gate time exits 2" 2
FC --gate-at "2026-12-04 23:00:00"
exit_is "a gate time without T and Z exits 2" 2
FC --now yesterday
exit_is "a bad --now exits 2" 2
FC --bogus
exit_is "an unknown flag exits 2" 2
FC --lender 0x123
exit_is "a bad address exits 2" 2
FC --min-tusd-lender 0.1234567
exit_is "more than 6 tUSD decimals exits 2" 2
FC --min-pol-lender abc
exit_is "a bad POL minimum exits 2" 2
FC --gate "../evil"
exit_is "a gate name with a slash exits 2" 2
FC --gate-at
exit_is "a flag without a value exits 2" 2
FC --deployments "$WORK/nope.json"
exit_is "a missing deployments file exits 2" 2
printf '{"chainId":1,"contracts":{"MockStablecoin":{"address":"%s"}}}\n' "$TOKEN_ADDR" >"$WORK/other.json"
FC --deployments "$WORK/other.json"
exit_is "a deployments file for another chain exits 2" 2

# defaults: the real deployments file and the evidence directory
rm -rf "$WORK/broadcast"
run bash "$HERE/funding-check.sh" --gate TB2 --gate-at "$GATE_AT" --now "$NOW_OK"
exit_is "defaults for deployments and evidence work" 0
holds "default evidence file name follows gate and time" test -f "$WORK/broadcast/gate-TB2-20261203T170000Z.json"
eq "default deployments file gives the real token" "$(jq -r '.contracts.MockStablecoin.address' "$REPO/deployments/amoy.json")" "$(jq -r .token "$WORK/broadcast/gate-TB2-20261203T170000Z.json")"
rm -rf "$WORK/broadcast"

# the real clock is used without --now
rm -f "$EV"
run bash "$HERE/funding-check.sh" --gate REHEARSAL-1 --gate-at 2099-01-01T00:00:00Z --deployments "$DEPLOY" --evidence "$EV"
exit_is "the real clock far before the gate qualifies" 0
eq "without --now the clock is not overridden" false "$(ev .clockOverridden)"
eq "without --now qualifying is true" true "$(ev .qualifying)"

# ---------------------------------------------------------------- 6. funding-check: no leaks

FC
holds "evidence is valid JSON" jq -e . "$EV"
holds "output hides the RPC URL" not_has CANARYKEY
holds "output hides the RPC host" not_has rpc.example.invalid
holds "evidence has no canary key" bash -c "! grep -q CANARYKEY '$EV'"
holds "evidence has no host" bash -c "! grep -q 'rpc.example.invalid' '$EV'"
holds "evidence has no URL at all" bash -c "! grep -Eqi 'https?:' '$EV'"
holds "evidence has no secret words" bash -c "! grep -Eqi 'password|private|keystore|mnemonic' '$EV'"
holds "cast never saw the RPC URL in argv" not_logged rpc.example.invalid
holds "cast never saw a key flag" not_logged --private-key
eq "evidence top level keys" "allowLate,blockNumber,chainId,checkedAt,clockOverridden,gate,gateAt,leadHours,minimums,qualifying,result,token,wallets" "$(jq -r 'keys | join(",")' "$EV")"
eq "wallet object keys" "address,flags,mintHeadroomBase,mintedToBase,polWei,role,status,tusdBase" "$(jq -r '.wallets[0] | keys | join(",")' "$EV")"

echo "gate-test: ok $CASES cases"
