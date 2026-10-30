#!/usr/bin/env bash
# Offline tests for the wallet pool scripts. A stub `cast` stands in for the network, so the suite
# needs no RPC, no keys and no funds. Run from anywhere. Needs jq. Compatible with bash 3.2.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CANARY="https://rpc.example.invalid/v2/CANARYKEYCANARYKEY0123456789"
mkdir -p "$WORK/bin" "$WORK/balances" "$WORK/home"

# Stub cast: chain-id, balance, send, wallet new, to-check-sum-address. Logs every call.
cat >"$WORK/bin/cast" <<'STUB'
#!/usr/bin/env bash
echo "cast $*" >>"$STUB_LOG"
case "$1" in chain-id | balance | send)
  [ -n "${ETH_RPC_URL:-}" ] || { echo "stub: ETH_RPC_URL missing" >&2; exit 9; } ;;
esac
case "$*" in *rpc.example.invalid*) echo "stub: rpc url leaked into argv" >&2; exit 9 ;; esac
case "$1" in
  chain-id) [ -z "${STUB_RPC_DOWN:-}" ] || { echo "connection refused for $ETH_RPC_URL" >&2; exit 1; }
            echo "${STUB_NETWORK:-80002}" ;;
  balance)  cat "$STUB_BALANCES/$2" ;;
  send)     echo '{"transactionHash":"0xabc123","status":"0x1"}' ;;
  wallet)   dir="$3"; name="$4"
            n="$(printf '%s' "$name" | cksum | cut -d' ' -f1)"
            addr="$(printf '%040x' "$n")"
            printf '{"address":"%s","crypto":{}}\n' "$addr" >"$dir/$name" ;;
  to-check-sum-address) echo "$2" ;;
  *) exit 8 ;;
esac
STUB
chmod +x "$WORK/bin/cast"

export PATH="$WORK/bin:$PATH"
export STUB_LOG="$WORK/calls.log"
export STUB_BALANCES="$WORK/balances"
export LATIFI_HOME="$WORK/home/.latifi"
export DEMO_WALLETS_MANIFEST="$WORK/demo-wallets.json"
export AMOY_RPC_URL="$CANARY"
: >"$STUB_LOG"

pass=0
fail=0
check() { # name, expected exit, actual exit
  if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "PASS $1"; else fail=$((fail + 1)); echo "FAIL $1 (expected exit $2, got $3)"; fi
}
ok() { # name, condition result
  if [ "$2" = "0" ]; then pass=$((pass + 1)); echo "PASS $1"; else fail=$((fail + 1)); echo "FAIL $1"; fi
}

run() { OUT="$("$@" 2>&1)"; RC=$?; }

# 1. new-pool creates six keystores, a 600 password, a 700 directory and a manifest.
run bash "$HERE/new-pool.sh"
check "new-pool exits 0" 0 "$RC"
ok "six keystores" "$([ "$(ls "$LATIFI_HOME/keystores" | wc -l | tr -d ' ')" = 6 ]; echo $?)"
perm() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }
ok "home mode 700" "$([ "$(perm "$LATIFI_HOME")" = 700 ]; echo $?)"
ok "password mode 600" "$([ "$(perm "$LATIFI_HOME/keystore-password")" = 600 ]; echo $?)"
ok "manifest shape" "$(jq -e '.chainId == 80002 and (.wallets | length) == 6 and ([.wallets[].role] | sort) == ["borrower-1","borrower-2","borrower-3","deployer","lender-1","lender-2"] and ([.wallets[].address | test("^0x[0-9a-fA-F]{40}$")] | all)' "$DEMO_WALLETS_MANIFEST" >/dev/null; echo $?)"
ok "manifest has no secret fields" "$(! grep -Eiq 'password|keystore|private' "$DEMO_WALLETS_MANIFEST"; echo $?)"
PW="$(cat "$LATIFI_HOME/keystore-password")"
ok "new-pool output hides the password" "$(! printf '%s' "$OUT" | grep -qF "$PW"; echo $?)"
before="$(cksum <"$LATIFI_HOME/keystores/deployer")"
run bash "$HERE/new-pool.sh"
ok "second new-pool keeps keystores" "$([ "$(cksum <"$LATIFI_HOME/keystores/deployer")" = "$before" ]; echo $?)"

# 2. chain id guard: wrong chain, unreachable RPC and missing URL all exit 3 and never leak the URL.
set_balances() { # deployer, others (wei)
  for role in deployer lender-1 lender-2 borrower-1 borrower-2 borrower-3; do
    a="$(jq -r --arg r "$role" '.wallets[] | select(.role==$r) | .address' "$DEMO_WALLETS_MANIFEST")"
    if [ "$role" = deployer ]; then printf '%s' "$1" >"$STUB_BALANCES/$a"; else printf '%s' "$2" >"$STUB_BALANCES/$a"; fi
  done
}
set_balances 1000000000000000000 100000000000000000

STUB_NETWORK=1 run bash "$HERE/check-balances.sh"
check "check-balances refuses chain 1" 3 "$RC"
ok "wrong-chain message hides the key" "$(! printf '%s' "$OUT" | grep -q CANARYKEY; echo $?)"
STUB_NETWORK=137 run bash "$HERE/top-up.sh" --to all --amount 0.1
check "top-up refuses chain 137" 3 "$RC"
STUB_RPC_DOWN=1 run bash "$HERE/check-balances.sh"
check "check-balances exits 3 when RPC is down" 3 "$RC"
ok "down-RPC message hides the key" "$(! printf '%s' "$OUT" | grep -q CANARYKEY; echo $?)"
ok "down-RPC message names the host" "$(printf '%s' "$OUT" | grep -q 'rpc.example.invalid'; echo $?)"
AMOY_RPC_URL="" run bash "$HERE/check-balances.sh"
check "check-balances exits 3 without a URL" 3 "$RC"

# 3. balances: all OK, then one LOW.
run bash "$HERE/check-balances.sh"
check "all wallets OK exits 0" 0 "$RC"
ok "six OK rows" "$([ "$(printf '%s\n' "$OUT" | grep -c ' OK$')" = 6 ]; echo $?)"
ok "table hides the key" "$(! printf '%s' "$OUT" | grep -q CANARYKEY; echo $?)"
run bash "$HERE/check-balances.sh" --json
ok "json all OK" "$(printf '%s' "$OUT" | jq -e 'length == 6 and all(.[]; .status == "OK")' >/dev/null; echo $?)"
ok "json fields" "$(printf '%s' "$OUT" | jq -e 'all(.[]; keys == ["address","balancePol","role","status"])' >/dev/null; echo $?)"
set_balances 299999999999999999 100000000000000000
run bash "$HERE/check-balances.sh"
check "deployer one wei below 0.3 is LOW, exit 1" 1 "$RC"
set_balances 300000000000000000 99999999999999999
run bash "$HERE/check-balances.sh" --json
check "pool wallet one wei below 0.1 is LOW, exit 1" 1 "$RC"
ok "json reports LOW" "$(printf '%s' "$OUT" | jq -e 'any(.[]; .status == "LOW")' >/dev/null; echo $?)"
set_balances 300000000000000000 100000000000000000
run bash "$HERE/check-balances.sh"
check "exact minimums are OK" 0 "$RC"
set_balances 123456789012345678901234567890 100000000000000000
run bash "$HERE/check-balances.sh" --json
ok "very large balances compare exactly" "$(printf '%s' "$OUT" | jq -e 'all(.[]; .status == "OK")' >/dev/null; echo $?)"

# 4. top-up: cap, validation, dry run, real send.
set_balances 1000000000000000000 100000000000000000
: >"$STUB_LOG"
run bash "$HERE/top-up.sh" --to all --amount 1.000000000000000001
check "amount above 1 POL rejected" 2 "$RC"
run bash "$HERE/top-up.sh" --to all --amount 5
check "amount 5 rejected" 2 "$RC"
run bash "$HERE/top-up.sh" --to all --amount abc
check "non numeric amount rejected" 2 "$RC"
run bash "$HERE/top-up.sh" --to all --amount 0
check "zero amount rejected" 2 "$RC"
run bash "$HERE/top-up.sh" --to nobody --amount 0.1
check "unknown role rejected" 2 "$RC"
run bash "$HERE/top-up.sh" --to deployer --amount 0.1
check "deployer self top-up rejected" 2 "$RC"
run bash "$HERE/top-up.sh" --amount 0.1
check "missing --to rejected" 2 "$RC"
ok "rejections made no cast send" "$(! grep -q 'cast send' "$STUB_LOG"; echo $?)"
run bash "$HERE/top-up.sh" --to all --amount 0.1 --dry-run
check "dry run exits 0" 0 "$RC"
ok "dry run lists five recipients" "$([ "$(printf '%s\n' "$OUT" | grep -cE '^  (lender|borrower)-')" = 5 ]; echo $?)"
ok "dry run sends nothing" "$(! grep -q 'cast send' "$STUB_LOG"; echo $?)"
run bash "$HERE/top-up.sh" --to lender-1 --amount 1 --dry-run
check "exactly 1 POL is allowed" 0 "$RC"
set_balances 400000000000000000 100000000000000000
run bash "$HERE/top-up.sh" --to all --amount 0.1
check "insufficient deployer balance exits 1" 1 "$RC"
set_balances 1000000000000000000 100000000000000000
run bash "$HERE/top-up.sh" --to all --amount 0.1
check "real top-up exits 0" 0 "$RC"
ok "five sends" "$([ "$(grep -c '^cast send' "$STUB_LOG")" = 5 ]; echo $?)"
ok "send output hides password and key" "$(! printf '%s' "$OUT" | grep -qE "CANARYKEY|$PW"; echo $?)"
ok "send argv has no password" "$(! grep -qF "$PW" "$STUB_LOG"; echo $?)"

# 5. lib arithmetic.
. "$HERE/lib.sh"
ok "pol_to_wei 0.3" "$([ "$(pol_to_wei 0.3)" = 300000000000000000 ]; echo $?)"
ok "pol_to_wei 1" "$([ "$(pol_to_wei 1)" = 1000000000000000000 ]; echo $?)"
ok "pol_to_wei rejects 1.2.3" "$(! pol_to_wei 1.2.3 >/dev/null; echo $?)"
ok "pol_to_wei rejects 19 decimals" "$(! pol_to_wei 0.1234567890123456789 >/dev/null; echo $?)"
ok "wei_to_pol 1" "$([ "$(wei_to_pol 1)" = 0.000000000000000001 ]; echo $?)"
ok "wei_to_pol 0" "$([ "$(wei_to_pol 0)" = 0.0 ]; echo $?)"
ok "wei_to_pol 1.5 POL" "$([ "$(wei_to_pol 1500000000000000000)" = 1.5 ]; echo $?)"
ok "wei_ge by length" "$(wei_ge 1000 999; echo $?)"
ok "wei_ge equal" "$(wei_ge 500 500; echo $?)"
ok "wei_ge lexicographic" "$(! wei_ge 499 500; echo $?)"
ok "wei_ge leading zeros" "$(wei_ge 0010 9; echo $?)"
ok "wei_add carries" "$([ "$(wei_add 999 1)" = 1000 ]; echo $?)"

echo "wallets tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ] && echo "PASS $pass/$pass" || exit 1
