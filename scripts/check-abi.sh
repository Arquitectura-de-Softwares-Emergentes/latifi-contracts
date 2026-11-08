#!/usr/bin/env bash
# Drift check for the v0 loan event ABI.
# Rebuilds the interface and the LoanBook contract, normalizes their event ABIs to events sorted by
# name, and diffs both against abi/loan-events.v0.json. Also rejects any entry or parameter in the
# ILoanEvents, LoanBook and MockStablecoin ABIs that looks like a price or exchange rate, because
# the exchange rate must stay off-chain (TC-05, DR-01).
# Run from the repo root. Needs forge and jq. Compatible with bash 3.2.
set -euo pipefail

INTERFACE="src/interfaces/ILoanEvents.sol:ILoanEvents"
LOANBOOK="src/LoanBook.sol:LoanBook"
TOKEN="src/MockStablecoin.sol:MockStablecoin"
COMMITTED="abi/loan-events.v0.json"
FORBIDDEN='price|fxrate|exchange|oracle'

if [ ! -f "$COMMITTED" ]; then
  echo "abi-check: missing $COMMITTED" >&2
  exit 1
fi

forge build >/dev/null

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
GENERATED="$TMP_DIR/generated.json"
LOANBOOK_EVENTS="$TMP_DIR/loanbook-events.json"
EXPECTED="$TMP_DIR/expected.json"

forge inspect "$INTERFACE" abi --json \
  | jq -S '[.[] | select(.type == "event")] | sort_by(.name)' >"$GENERATED"
forge inspect "$LOANBOOK" abi --json \
  | jq -S '[.[] | select(.type == "event")] | sort_by(.name)' >"$LOANBOOK_EVENTS"
jq -S 'sort_by(.name)' "$COMMITTED" >"$EXPECTED"

STATUS=0

if ! diff -u "$EXPECTED" "$GENERATED"; then
  echo "abi-check: $COMMITTED differs from the compiled interface (diff above)" >&2
  STATUS=1
fi

if ! diff -u "$EXPECTED" "$LOANBOOK_EVENTS"; then
  echo "abi-check: $COMMITTED differs from the events of the compiled LoanBook (diff above)" >&2
  STATUS=1
fi

BAD_INPUTS="$(jq -r --arg re "$FORBIDDEN" \
  '.[] | .name as $event | .inputs[] | select(.name | test($re; "i")) | "\($event).\(.name)"' \
  "$GENERATED")"
if [ -n "$BAD_INPUTS" ]; then
  echo "abi-check: event inputs that look like a price or exchange rate are not allowed:" >&2
  echo "$BAD_INPUTS" >&2
  STATUS=1
fi

# Wider scan: every entry name and every input or output parameter name, including the names of
# the components of tuples, in the ABI of each contract.
for contract in "$INTERFACE" "$LOANBOOK" "$TOKEN"; do
  BAD_NAMES="$(forge inspect "$contract" abi --json | jq -r --arg re "$FORBIDDEN" --arg c "$contract" '
    def pnames: (.name // empty), ((.components // [])[] | pnames);
    .[] | (.name // "") as $entry
        | (select($entry | test($re; "i")) | "\($c).\($entry)"),
          ( ((.inputs // [])[], (.outputs // [])[]) | pnames
            | select(test($re; "i")) | "\($c).\($entry).\(.)" )')"
  if [ -n "$BAD_NAMES" ]; then
    echo "abi-check: names that look like a price or exchange rate are not allowed:" >&2
    echo "$BAD_NAMES" >&2
    STATUS=1
  fi
done

if [ "$STATUS" -ne 0 ]; then
  exit 1
fi

echo "abi-check: ok"
