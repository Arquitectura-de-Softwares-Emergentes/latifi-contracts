#!/usr/bin/env bash
# cycle.test.sh: offline self-test for cycle.sh.
#
# A stub `cast` stands in for the chain. It keeps the state of a tiny loan book in files, logs every
# call and reverts a repayment that is not exactly the current installment, so the test needs no
# RPC, no keys and no funds. Needs python3 for the JSON check. Works on macOS bash 3.2 and Ubuntu
# bash 5.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
CYCLE="$HERE/cycle.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

STATE="$WORK/state"
mkdir -p "$WORK/bin" "$STATE"

LENDER="0xA22412ba83539ACFd3385DA78F6214E800E865a3"
BORROWER="0xcb9003E7f369AE9b55C18D8cfEC8A32a12ee61F0"
TOKEN="0x00000000000000000000000000000000000000a1"
BOOK="0x00000000000000000000000000000000000000b2"
FAKE_RPC="http://rpc.example.invalid:8545"

# The strings below are built from pieces so that this file never holds a raw key flag as one word.
KEY_FLAG="--private""-key"
MNEMONIC_FLAG="--mne""monic"

cat >"$WORK/bin/cast" <<'STUB'
#!/usr/bin/env bash
# Stub cast. State lives in $STUB_STATE, one file per value.
echo "cast $*" >>"$STUB_LOG"
S="$STUB_STATE"
lc() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }
get() { if [ -f "$S/$1" ]; then cat "$S/$1"; else echo "${2:-0}"; fi; }
put() { printf '%s' "$2" >"$S/$1"; }
big() { # value, annotated like cast does for large numbers
  if [ "$1" -ge 100000 ]; then echo "$1 [1e8]"; else echo "$1"; fi
}
sub="$1"
shift
case "$sub" in
  chain-id)
    echo "${STUB_CHAIN:-80002}"
    ;;
  balance)
    a="$(lc "$1")"
    if [ -f "$S/pol-$a" ]; then cat "$S/pol-$a"; echo; else echo "${STUB_POL:-1000000000000000000}"; fi
    ;;
  call)
    target="$1"
    sig="$2"
    shift 2
    case "$sig" in
      totalDueFor*)
        p="$1"; r="$2"; t="$3"
        big $((p + p * r * t / 3650000))
        ;;
      balanceOf*) big "$(get "bal-$(lc "$1")")" ;;
      loanCount*) get loanCount ;;
      getLoan*)
        echo "($(get borrower 0x0), 1000 [1e3], 1, $(get n 2), $(get status 0), $(get lender 0x0), $(get fundedAt 0), $(big "$(get principal)"), $(big "$(get totalDue)"), $(big "$(get paid)"))"
        ;;
      reputationOf*) echo "($(get on 0), $(get late 0), $(get def 0))" ;;
      nextInstallment*)
        n="$(get n 2)"; total="$(get totalDue)"; paid="$(get paid)"
        base=$((total / n))
        k=$((paid / base + 1))
        [ "$k" -le "$n" ] || k="$n"
        if [ "$k" -eq "$n" ]; then target_amt="$total"; else target_amt=$((k * base)); fi
        echo "$k"
        echo "1793420399 [1.793e9]"
        big $((target_amt - paid))
        ;;
      *) echo "stub: unknown call $sig" >&2; exit 9 ;;
    esac
    ;;
  send)
    target="$1"
    sig="$2"
    shift 2
    # arguments of the function, then flags
    args=()
    while [ $# -gt 0 ]; do
      case "$1" in -*) break ;; esac
      args+=("$1")
      shift
    done
    who=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --account | --keystore) who="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    case "$who" in
      *lender*) me="$LENDER_ADDR" ;;
      *borrower*) me="$BORROWER_ADDR" ;;
      *) echo "stub: unknown signer '$who'" >&2; exit 9 ;;
    esac
    [ -z "${STUB_SEND_FAILS:-}" ] || { echo "stub: send rejected" >&2; exit 1; }
    revert() { echo "stub: execution reverted: $1" >&2; exit 1; }
    case "$sig" in
      mint*) put "bal-$(lc "$me")" $(($(get "bal-$(lc "$me")") + ${args[0]})) ;;
      approve*) put "allow-$(lc "$me")" "${args[1]}" ;;
      requestLoan*)
        n=$(($(get loanCount) + 1))
        put loanCount "$n"
        put borrower "$me"
        put principal "${args[0]}"
        put n "${args[3]}"
        put status 1
        put paid 0
        put lender 0x0
        put totalDue 0
        ;;
      fund*)
        [ "$(get status)" = 1 ] || revert LoanNotOpen
        p="$(get principal)"
        [ "$(get "allow-$(lc "$me")")" -ge "$p" ] || revert allowance
        [ "$(get "bal-$(lc "$me")")" -ge "$p" ] || revert balance
        put "allow-$(lc "$me")" $(($(get "allow-$(lc "$me")") - p))
        put "bal-$(lc "$me")" $(($(get "bal-$(lc "$me")") - p))
        b="$(lc "$(get borrower)")"
        put "bal-$b" $(($(get "bal-$b") + p))
        put lender "$me"
        put fundedAt 1793420000
        put totalDue $((p + p * 1000 * 1 / 3650000))
        put status 2
        ;;
      repay*)
        [ "$(get status)" = 2 ] || revert LoanNotActive
        n="$(get n 2)"; total="$(get totalDue)"; paid="$(get paid)"
        base=$((total / n)); k=$((paid / base + 1)); [ "$k" -le "$n" ] || k="$n"
        if [ "$k" -eq "$n" ]; then target_amt="$total"; else target_amt=$((k * base)); fi
        want=$((target_amt - paid))
        [ "${args[1]}" -eq "$want" ] || revert "amount ${args[1]} is not the installment $want"
        [ "$(get "allow-$(lc "$me")")" -ge "$want" ] || revert allowance
        put "allow-$(lc "$me")" $(($(get "allow-$(lc "$me")") - want))
        put "bal-$(lc "$me")" $(($(get "bal-$(lc "$me")") - want))
        l="$(lc "$(get lender)")"
        put "bal-$l" $(($(get "bal-$l") + want))
        put paid $((paid + want))
        [ $((paid + want)) -ne "$total" ] || put status 3
        put on $(($(get on) + 1))
        put repays $(($(get repays) + 1))
        ;;
      *) echo "stub: unknown send $sig" >&2; exit 9 ;;
    esac
    c=$(($(get txcount) + 1))
    put txcount "$c"
    printf '{"transactionHash":"0x%064x","blockNumber":"0x%x","status":"0x1","from":"%s"}\n' "$c" $((100 + c)) "$me"
    ;;
  logs)
    n="$(get repays)"
    i=0
    while [ "$i" -lt "$n" ]; do
      echo "- address: $BOOK_ADDR"
      echo "  blockNumber: $((200 + i))"
      i=$((i + 1))
    done
    ;;
  *) echo "stub: unknown cast subcommand $sub" >&2; exit 9 ;;
esac
STUB
chmod +x "$WORK/bin/cast"

export PATH="$WORK/bin:$PATH"
export STUB_LOG="$WORK/calls.log"
export STUB_STATE="$STATE"
export LENDER_ADDR="$LENDER"
export BORROWER_ADDR="$BORROWER"
export BOOK_ADDR="$BOOK"

pass=0
fail=0
total=0
check() { # NAME CONDITION_EXIT_CODE
  total=$((total + 1))
  if [ "$2" = "0" ]; then
    pass=$((pass + 1))
    echo "PASS $1"
  else
    fail=$((fail + 1))
    echo "FAIL $1"
  fi
}
expect_rc() { # NAME EXPECTED ACTUAL
  total=$((total + 1))
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1))
    echo "PASS $1"
  else
    fail=$((fail + 1))
    echo "FAIL $1 (expected exit $2, got $3)"
  fi
}

reset() { # clears the stub state and the call log
  rm -rf "$STATE"
  mkdir -p "$STATE"
  : >"$STUB_LOG"
  unset STUB_CHAIN STUB_POL STUB_SEND_FAILS
}

sends() { grep -c '^cast send' "$STUB_LOG" || true; }

BASE_ARGS=(--rpc-url "$FAKE_RPC" --token "$TOKEN" --book "$BOOK"
  --lender-account lender-acct --borrower-account borrower-acct)

run() { OUT="$("$@" 2>&1)"; RC=$?; }

# 1. A normal run on Amoy.
reset
EV="$WORK/ev-80002.json"
run bash "$CYCLE" "${BASE_ARGS[@]}" --evidence "$EV"
expect_rc "normal run exits 0" 0 "$RC"
check "normal run prints cycle-ok last" "$([ "$(printf '%s\n' "$OUT" | tail -n 1)" = "cycle-ok" ]; echo $?)"
NSENDS="$(sends)"
check "eight transactions were sent" "$([ "$NSENDS" = 8 ]; echo $?)"

# 2. The evidence file.
python3 -I - "$EV" "$NSENDS" <<'PY'
import json, re, sys
d = json.load(open(sys.argv[1]))
want = ["chainId", "token", "book", "loanId", "principal", "totalDue", "installments",
        "txs", "finalStatus", "counters", "repaidEvents"]
assert sorted(d) == sorted(want), sorted(d)
assert d["finalStatus"] == 3
assert d["chainId"] == 80002 and d["loanId"] == 1 and d["installments"] == 2
assert d["principal"] == "100000000" and d["totalDue"] == "100027397"
assert len(d["txs"]) == int(sys.argv[2])
assert all(re.fullmatch(r"0x[0-9a-f]{64}", t["hash"]) for t in d["txs"])
assert all(isinstance(t["block"], int) and isinstance(t["name"], str) for t in d["txs"])
assert d["counters"] == {"onTime": 2, "late": 0, "defaulted": 0}
assert d["repaidEvents"] == 2
PY
check "evidence file has the expected keys, types and one tx per send" "$?"

# 3. Approvals are exact and repayments follow nextInstallment.
LEND_APPROVE="$(grep '^cast send' "$STUB_LOG" | grep 'approve(address,uint256)' | grep 'lender-acct' | awk '{for(i=1;i<=NF;i++) if($i ~ /^approve/) print $(i+2)}')"
BORR_APPROVE="$(grep '^cast send' "$STUB_LOG" | grep 'approve(address,uint256)' | grep 'borrower-acct' | awk '{for(i=1;i<=NF;i++) if($i ~ /^approve/) print $(i+2)}')"
check "lender approval is exactly the principal" "$([ "$LEND_APPROVE" = "100000000" ]; echo $?)"
check "borrower approval is exactly the total due" "$([ "$BORR_APPROVE" = "100027397" ]; echo $?)"
REPAYS="$(grep '^cast send' "$STUB_LOG" | grep 'repay(uint256,uint256)' | awk '{for(i=1;i<=NF;i++) if($i ~ /^repay/) print $(i+2)}' | tr '\n' ' ')"
check "repayments equal the nextInstallment amounts" "$([ "$REPAYS" = "50013698 50013699 " ]; echo $?)"

# 4. No secret ever reaches cast.
check "no raw key flag in any cast call" "$(! grep -q -e "$KEY_FLAG" "$STUB_LOG"; echo $?)"
check "no mnemonic flag in any cast call" "$(! grep -q -e "$MNEMONIC_FLAG" "$STUB_LOG"; echo $?)"
check "no password literal in any cast call" "$(! grep -E -q -e '--password [^ ]|--unsafe-password' "$STUB_LOG"; echo $?)"
check "cycle.sh itself has no raw key flag or mnemonic option" "$(! grep -q -e "$KEY_FLAG" -e "$MNEMONIC_FLAG" "$CYCLE"; echo $?)"
check "cycle.sh holds no 64 hex literal" "$(! grep -E -q '[0-9a-fA-F]{64}' "$CYCLE"; echo $?)"
check "Amoy sends carry the explicit gas flags" "$(grep '^cast send' "$STUB_LOG" | grep -q -e '--gas-price 35gwei --priority-gas-price 30gwei'; echo $?)"
check "account form passes --account" "$(grep '^cast send' "$STUB_LOG" | grep -q -e '--account lender-acct'; echo $?)"

# 5. Wrong chain id: exit 3 and nothing sent.
reset
STUB_CHAIN=1234 run bash "$CYCLE" "${BASE_ARGS[@]}" --evidence "$WORK/ev-x.json"
expect_rc "wrong chain id exits 3" 3 "$RC"
check "wrong chain id sends nothing" "$([ "$(sends)" = 0 ]; echo $?)"

# 6. Low POL: exit 4, the address is named and nothing is sent.
reset
mkdir -p "$STATE"
printf '%s' "10000000000000000" >"$STATE/pol-$(printf '%s' "$BORROWER" | tr 'A-Z' 'a-z')"
run bash "$CYCLE" "${BASE_ARGS[@]}" --evidence "$WORK/ev-x.json"
expect_rc "low POL exits 4" 4 "$RC"
check "low POL names the wallet and the shortfall" "$(printf '%s' "$OUT" | grep -q "$BORROWER" && printf '%s' "$OUT" | grep -q 'short by 0.04 POL'; echo $?)"
check "low POL sends nothing" "$([ "$(sends)" = 0 ]; echo $?)"

# 7. A balance exactly at the minimum passes.
reset
printf '%s' "50000000000000000" >"$STATE/pol-$(printf '%s' "$BORROWER" | tr 'A-Z' 'a-z')"
run bash "$CYCLE" "${BASE_ARGS[@]}" --evidence "$WORK/ev-min.json"
expect_rc "a balance equal to --min-pol passes" 0 "$RC"

# 8. Chain ids outside the allow-list.
reset
run bash "$CYCLE" "${BASE_ARGS[@]}" --chain-id 5
expect_rc "--chain-id 5 exits 2" 2 "$RC"
run bash "$CYCLE" "${BASE_ARGS[@]}" --chain-id abc
expect_rc "--chain-id abc exits 2" 2 "$RC"
run bash "$CYCLE" --dry-run --chain-id 11155111 --token "$TOKEN" --book "$BOOK" --lender-account a --borrower-account b
expect_rc "a dry run with another chain exits 2" 2 "$RC"
check "usage errors make no cast call" "$([ ! -s "$STUB_LOG" ]; echo $?)"

# 9. Dry run: exit 0, no cast call at all, the command list shows the gas flags.
reset
run bash "$CYCLE" --dry-run --token "$TOKEN" --book "$BOOK" --lender-account latifi-lender --borrower-account latifi-borrower
expect_rc "dry run exits 0" 0 "$RC"
check "dry run makes no cast call" "$([ ! -s "$STUB_LOG" ]; echo $?)"
check "dry run shows the Amoy gas flags" "$(printf '%s' "$OUT" | grep -q -e '--priority-gas-price 30gwei'; echo $?)"
check "dry run never prints the RPC url" "$(! printf '%s' "$OUT" | grep -q 'example.invalid'; echo $?)"

# 10. Argument checks.
reset
run bash "$CYCLE" "${BASE_ARGS[@]}" --principal 1000000001
expect_rc "a principal above the mint cap exits 2" 2 "$RC"
run bash "$CYCLE" --token "$TOKEN" --book "$BOOK" --lender-account l --borrower-account b
expect_rc "a missing --rpc-url exits 2" 2 "$RC"
run bash "$CYCLE" "${BASE_ARGS[@]}" --gas-flags "$KEY_FLAG abc"
expect_rc "a gas flag string that smuggles another flag exits 2" 2 "$RC"
run bash "$CYCLE" --rpc-url "$FAKE_RPC" --token "$TOKEN" --book "$BOOK" --lender-account l
expect_rc "a missing borrower signer exits 2" 2 "$RC"
check "argument errors send nothing" "$([ "$(sends)" = 0 ]; echo $?)"

# 11. Keystore plus password file form, on the local chain without gas flags.
reset
export STUB_CHAIN=31337
run bash "$CYCLE" --rpc-url "$FAKE_RPC" --chain-id 31337 --token "$TOKEN" --book "$BOOK" \
  --lender-keystore "$WORK/ks/lender" --lender-password-file "$WORK/pw" \
  --borrower-keystore "$WORK/ks/borrower" --borrower-password-file "$WORK/pw" \
  --evidence "$WORK/ev-31337.json"
expect_rc "keystore form on the local chain exits 0" 0 "$RC"
check "keystore form passes --keystore and --password-file" "$(grep '^cast send' "$STUB_LOG" | grep -q -e "--keystore $WORK/ks/lender --password-file $WORK/pw"; echo $?)"
check "local chain sends no gas flags" "$(! grep '^cast send' "$STUB_LOG" | grep -q -e '--gas-price'; echo $?)"
check "local evidence names chain 31337" "$(grep -q '"chainId":31337' "$WORK/ev-31337.json"; echo $?)"

# 12. A rejected transaction ends the run with exit 1.
reset
STUB_SEND_FAILS=1 run bash "$CYCLE" "${BASE_ARGS[@]}" --evidence "$WORK/ev-x.json"
expect_rc "a rejected send exits 1" 1 "$RC"

echo "PASS $pass/$total"
[ "$fail" -eq 0 ]
