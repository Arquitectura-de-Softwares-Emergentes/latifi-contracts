# Loan events, version 0

This file describes the four events that every other LatiFi component reads from the chain. The source of truth is `src/interfaces/ILoanEvents.sol`. The same events are published as JSON in `abi/loan-events.v0.json`, and `scripts/check-abi.sh` fails CI when the two disagree.

Status: v0 draft. The API indexer (Phase 4) and the Android app (Phase 5) can build fixtures against it now. Phase 3 freezes the interface after reviewing the real contract, and until then any change goes into the changelog at the end of this file.

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

`interestRateBps` is flat interest over the whole term, not per month and not annualized. The total owed is `amount + amount * interestRateBps / 10000`.

## LoanRequested

Emitted when the borrower's request is stored on-chain. The request is open from this moment until a lender funds it.

| Field | Solidity type | Indexed | Unit | Meaning |
|-------|---------------|---------|------|---------|
| loanId | uint256 | yes | none | Identifier assigned to the request. |
| borrower | address | yes | none | Wallet that asked for the loan. |
| amount | uint256 | no | stablecoin base units | Requested principal. |
| interestRateBps | uint16 | no | bps | Flat interest over the whole term. |
| termDays | uint32 | no | days | Length of the loan, counted from the funding time. |
| installments | uint8 | no | count | Number of equal installments, 1 to 6. |

## LoanFunded

Emitted when a lender funds an open request. The principal moves to the borrower and the terms are locked in the same transaction.

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
| onTime | bool | no | none | True when the payment arrived on or before the due date it applies to. |

## LoanDefaulted

Emitted once, when an overdue loan is marked as defaulted.

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
| LoanDefaulted | Someone marks a loan whose due date has passed with an unpaid balance. |

## Installment schedule

The contract stores no list of dates. Consumers derive the schedule from three values: `fundedAt` and `dueDate` from `LoanFunded`, and `installments` and `termDays` from `LoanRequested`.

Installment k, for k from 1 to N, falls due at `fundedAt + k * termDays * 86400 / N` seconds, using integer division. Installment N therefore falls due exactly at `dueDate`. With N = 1 the only installment is the final one.

Each installment is `total / N`. Phase 3 decides how the rounding remainder is assigned, with the last installment as the working assumption, and records it here when the contract is reviewed.

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
