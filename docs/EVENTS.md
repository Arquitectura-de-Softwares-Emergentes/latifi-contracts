# Loan events, version 0

This file describes the four events that every other LatiFi component reads from the chain. The source of truth is `src/interfaces/ILoanEvents.sol`. The same events are published as JSON in `abi/loan-events.v0.json`, and `scripts/check-abi.sh` fails CI when the two disagree.

Status: v0 is frozen by Phase 3. The event interface matches the real `LoanBook` contract, and `abi/loan-events.v0.json` does not change. Changing the ABI needs a new version file and a row in the changelog at the end of this file. The rules of the contract (formula, schedule, default) are in `docs/LOANBOOK.md`.

## Rules that shape the events

- The loan lifecycle lives on-chain. The feed, the indexer and the reputation logic derive their state from these events and keep no loan state of their own.
- No event carries a price, an exchange rate or an oracle value. The local-currency amounts that the app shows are computed off-chain from LatiFi API. `check-abi.sh` rejects any event input named like price, fxrate, exchange or oracle.
- Repayment is made of N equal installments, with N from 1 to 6 (decision recorded in ADR-0004). N = 1 is the single-payment loan, so one interface covers both cases.

## Units

| Unit | Meaning |
|------|---------|
| Stablecoin amount | Base units of the test stablecoin, which has 6 decimals. `1000000` is one token. |
| Basis points (bps) | One hundredth of a percent. `1000` bps is 10 percent. |
| Timestamp | Unix seconds, as `uint64`. |
| Days | Whole days, as `uint32`. |

`interestRateBps` is an annual rate with simple interest, in basis points of the principal. It is valid from 1 to 5000, which is up to 50 percent a year. It is not compounded and it is not a rate for the whole term. The total owed is the principal plus `floor(principal * interestRateBps * termDays / 3650000)`. The contract computes it once when a lender funds the request and it never changes afterwards. The term is 1 to 365 days.

## LoanRequested

Emitted when the borrower's request is stored on-chain. The request is open from this moment until a lender funds it.

| Field | Solidity type | Indexed | Unit | Meaning |
|-------|---------------|---------|------|---------|
| loanId | uint256 | yes | none | Identifier assigned to the request. |
| borrower | address | yes | none | Wallet that asked for the loan. |
| amount | uint256 | no | stablecoin base units | Requested principal. |
| interestRateBps | uint16 | no | bps | Annual simple interest, 1 to 5000. |
| termDays | uint32 | no | days | Length of the loan, 1 to 365 days, counted from the funding time. |
| installments | uint8 | no | count | Number of equal installments, 1 to 6. |

## LoanFunded

Emitted when a lender funds an open request. The principal moves to the borrower and the terms are locked in the same transaction. The total due is computed and stored in this same transaction.

| Field | Solidity type | Indexed | Unit | Meaning |
|-------|---------------|---------|------|---------|
| loanId | uint256 | yes | none | The funded loan. |
| lender | address | yes | none | Wallet that provided the funds. |
| borrower | address | yes | none | Wallet that received the funds. |
| amount | uint256 | no | stablecoin base units | Principal transferred. |
| fundedAt | uint64 | no | Unix seconds | Moment the funds moved. |
| dueDate | uint64 | no | Unix seconds | Due date of the final installment. |

## LoanRepaid

Emitted on every payment toward a loan, including partial ones and the one that settles it. When the last payment settles the loan, the loan reaches the Repaid state in the same transaction.

| Field | Solidity type | Indexed | Unit | Meaning |
|-------|---------------|---------|------|---------|
| loanId | uint256 | yes | none | The loan being repaid. |
| amountPaid | uint256 | no | stablecoin base units | Amount moved by this payment only, not a running total. |
| onTime | bool | no | none | True when the payment arrived on or before the due time of the installment being paid. |

## LoanDefaulted

Emitted once, when a loan is marked as defaulted because an installment is more than 7 days overdue.

| Field | Solidity type | Indexed | Unit | Meaning |
|-------|---------------|---------|------|---------|
| loanId | uint256 | yes | none | The defaulted loan. |
| borrower | address | yes | none | Wallet that did not repay. |
| outstandingAmount | uint256 | no | stablecoin base units | Amount still unpaid when the loan was marked. |

## When each event is emitted

| Event | Emitted when |
|-------|--------------|
| LoanRequested | The request is stored. No funds move. |
| LoanFunded | A lender's transfer to the borrower succeeds and the loan becomes active. |
| LoanRepaid | A payment transfer to the lender succeeds. One event per payment. |
| LoanDefaulted | Someone marks an active loan whose current installment is more than 7 days overdue. At exactly 7 days the call still reverts. |

## Installment schedule

The contract stores no list of dates. Consumers derive the schedule from three values: `fundedAt` and `dueDate` from `LoanFunded`, and `installments` and `termDays` from `LoanRequested`.

Installment k, for k from 1 to N, falls due at `fundedAt + k * termDays * 86400 / N` seconds, using integer division. Installment N therefore falls due exactly at `dueDate`. With N = 1 the only installment is the final one.

Each of the first N minus 1 installments is `floor(total / N)`. The last installment absorbs the rounding remainder: it is `total - (N - 1) * floor(total / N)`, which is larger than the others by at most N minus 1 base units. When `total` is smaller than N the first installments are 0 and the last one carries everything. The due times use integer division by N.

A payment never spans two installments. A loan with an unpaid installment keeps that installment as the current one until it is paid.

## Status values

The loan status is not part of an event. Consumers read it from `getLoan` or derive it from the events. The numeric values are frozen.

| Value | Name | How the events show it |
|-------|------|------------------------|
| 0 | None | No event exists for this id. |
| 1 | Open | LoanRequested seen, no LoanFunded yet. |
| 2 | Active | LoanFunded seen, not yet settled or defaulted. |
| 3 | Repaid | The LoanRepaid payments add up to the total due. |
| 4 | Defaulted | LoanDefaulted seen. |

## Consumers

| Consumer | What it reads | Notes |
|----------|---------------|-------|
| API indexer | All four events | Idempotency key is the transaction hash plus the log index, so a block that is read twice never creates a duplicate record. |
| Reputation | LoanFunded, LoanRepaid, LoanDefaulted | LoanFunded starts a loan. LoanRepaid with onTime true or false feeds the on-time and late counters. LoanDefaulted feeds the default counter. |
| Android app | Nothing directly | Reads loan data through the API and checks the loan status before critical actions. |

## Changelog

| Version | Change |
|---------|--------|
| v0 | Initial draft: four events, installments field on LoanRequested. |
| v0.1 | Interest meaning clarified as annual simple interest in basis points, ranges documented. Event ABI unchanged. |
| v0.2 | Remainder rule, default rule and status values documented. Event ABI unchanged. |
