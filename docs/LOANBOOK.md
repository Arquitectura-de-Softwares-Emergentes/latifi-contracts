# LoanBook rules

This file describes what the `LoanBook` contract does and the numbers it produces. The source is `src/LoanBook.sol`. The event payloads are in `docs/EVENTS.md`. Phase 4 (indexer and reputation) and Phase 5 (Android app) should treat this file as the written contract for the rules below.

## Purpose and custody

`LoanBook` stores every LatiFi loan and the per-borrower counters. It never holds tokens. Funding moves the principal from the lender wallet to the borrower wallet in one transaction, and every payment moves tokens from the borrower wallet to the lender wallet in one transaction. After any call the book balance of the lending token is zero.

The contract has no owner, no pause switch, no upgrade path, no function to take tokens out and no function to cancel a request. The token address is a constructor argument and cannot change.

## Status values

The numeric values are frozen. Clients decode them as `uint8`.

| Value | Name | Meaning |
|-------|------|---------|
| 0 | None | No loan exists with this id. Reads revert with `LoanNotFound`. |
| 1 | Open | The request is published and waiting for a lender. |
| 2 | Active | A lender funded the request and the repayment is running. |
| 3 | Repaid | The total due is fully paid. Final. |
| 4 | Defaulted | An installment was more than 7 days overdue and someone marked the loan. Final. |

Allowed transitions: None to Open (`requestLoan`), Open to Active (`fund`), Active to Repaid (the payment that makes `totalPaid` equal `totalDue`), Active to Defaulted (`markDefaulted`). Nothing leaves Repaid or Defaulted, and there is no way to leave Open other than being funded.

## Stored data

`getLoan(loanId)` returns the `Loan` struct as this tuple. The field order is frozen because Phase 5 generates its wrappers from it.

`(address,uint16,uint32,uint8,uint8,address,uint64,uint128,uint128,uint128)`

| Position | Field | Type | Set when |
|----------|-------|------|----------|
| 1 | borrower | address | request |
| 2 | interestRateBps | uint16 | request |
| 3 | termDays | uint32 | request |
| 4 | installments | uint8 | request |
| 5 | status | uint8 | changes with the life cycle |
| 6 | lender | address | funding, zero before |
| 7 | fundedAt | uint64 | funding, zero before |
| 8 | principal | uint128 | request |
| 9 | totalDue | uint128 | funding, zero before |
| 10 | totalPaid | uint128 | grows with each payment |

`reputationOf(borrower)` returns the `Reputation` struct `(uint32,uint32,uint32)` in the order `onTime`, `late`, `defaulted`.

Borrower, rate, term, installments and principal never change after the request. Lender, fundedAt and totalDue are written once, in `fund`, and never change afterwards. No function can edit them.

## Functions

| Function | Who may call it | Event | What it does |
|----------|-----------------|-------|--------------|
| `requestLoan(amount, rateBps, termDays, installments)` | Anyone, becomes the borrower | LoanRequested | Stores an Open request. No tokens move. |
| `fund(loanId)` | Anyone except the borrower, needs allowance for the principal | LoanFunded | Moves the principal lender to borrower, fixes lender, fundedAt and totalDue, status Active. |
| `repay(loanId, amount)` | Only the borrower, needs allowance for the amount | LoanRepaid | Moves tokens borrower to lender and applies them to the current installment. |
| `markDefaulted(loanId)` | Anyone | LoanDefaulted | Sets Defaulted when the current installment is more than 7 days overdue. No tokens move. |
| `nextInstallment(loanId)` | Anyone, view | none | Returns index, due time and unpaid amount of the current installment of an Active loan. |
| `installmentDueAt(loanId, index)` | Anyone, view | none | Returns the due time of installment `index` of a funded loan. |
| `totalDueFor(principal, rateBps, termDays)` | Anyone, pure | none | Returns principal plus interest. |
| `dueDateOf(fundedAt, termDays)` | Anyone, pure | none | Returns `fundedAt + termDays days`. |
| `getLoan(loanId)` | Anyone, view | none | Returns the stored loan. |
| `reputationOf(borrower)` | Anyone, view | none | Returns the counters. |

Constants read by clients: `MAX_RATE_BPS` 5000, `MAX_TERM_DAYS` 365, `MAX_INSTALLMENTS` 6, `MAX_PRINCIPAL` (`type(uint128).max / 2`), `GRACE_PERIOD` 7 days. Also `TOKEN` and `loanCount`.

`repay` takes the tokens from the caller and requires the caller to be the borrower. A third party cannot spend the allowance a borrower gave to the book.

## Limits of a request

| Field | Accepted values |
|-------|-----------------|
| amount | 1 to `type(uint128).max / 2` base units |
| rate | 1 to 5000 bps a year |
| term | 1 to 365 days |
| installments | 1 to 6 |

The ceiling on the amount guarantees that the principal plus the largest possible interest still fits in the `uint128` fields.

## Interest

Interest is simple, annual and not compounded. The total due is

```
totalDue = principal + floor(principal * rateBps * termDays / 3650000)
```

The divisor 3650000 is 365 times 10000. One floor division by 3650000 gives the same result as dividing by 365 and then by 10000, so either reading of the formula is correct.

Rounding goes down, which favors the borrower and loses less than one base unit (0.000001 token) per loan. The contract computes `totalDue` once, when a lender funds the request, and stores it. It never recomputes it. Interest is at most half of the principal because the rate is at most 5000 bps and the term at most 365 days.

## Installments

A loan with N installments splits `totalDue` like this.

- Installments 1 to N minus 1 each equal `base = floor(totalDue / N)`.
- Installment N is `totalDue - (N - 1) * base`, so the last one absorbs the remainder. It is larger than the others by at most N minus 1 base units.
- Installment k falls due at `fundedAt + k * termDays * 1 days / N` seconds, using integer division. Installment N falls due exactly at `fundedAt + termDays days`, the due date in `LoanFunded`.
- If `totalDue` is smaller than N, then `base` is 0. In that case every unit sits on the last installment and the current installment is N from the first payment on.

The current installment is derived from `totalPaid`, so the contract stores no schedule. A payment never spans two installments. You may pay less than the current installment, as many times as you like, and each payment is one signal for the counters. Paying more than what is left on the current installment reverts with `Overpayment(amount, maxAllowed)`. A payment of zero reverts with `ZeroAmount`.

The loan becomes Repaid in the same transaction that makes `totalPaid` equal `totalDue`.

## Lateness

A payment is on time when `block.timestamp` is at or before the due time of the installment it applies to, which is the current installment at that moment. A payment exactly on the due second is on time and one second later is late. A late payment is accepted. It emits `LoanRepaid` with `onTime` false and increments the `late` counter.

An unpaid installment stays the current one until it is fully paid, even after the next installment's due time has passed.

## Default

Anyone can call `markDefaulted` when the current installment is strictly more than 7 days past its due time, that is `block.timestamp > dueAt + 7 days`. At exactly 7 days the call reverts with `NotOverdue(loanId, dueAt + 7 days)` and one second later it works. The grace period is a constant and no one can change it.

The call sets the status to Defaulted, adds one to the borrower's `defaulted` counter and emits `LoanDefaulted(loanId, borrower, totalDue - totalPaid)`. The amount is everything still unpaid, not only the overdue installment. A defaulted loan cannot be repaid and `repay` reverts with `LoanNotActive`. No tokens move when a loan is marked.

The test of "more than 7 days overdue" uses the current installment, so a borrower who paid installment 1 on time is judged on installment 2.

## Counters

| Counter | Changes when |
|---------|--------------|
| onTime | A payment arrives on time. One per payment. |
| late | A payment arrives late. One per payment. |
| defaulted | `markDefaulted` succeeds. One per default. |

Only `repay` and `markDefaulted` change the counters. Each change matches one event (`LoanRepaid` or `LoanDefaulted`), so the Phase 4 indexer can recompute the counters from events and compare them with `reputationOf`.

## Errors

| Error | Raised when |
|-------|-------------|
| ZeroTokenAddress | The constructor gets the zero address. |
| ZeroAmount | A request amount or a payment is zero. |
| AmountTooLarge(amount, max) | The request amount is above `MAX_PRINCIPAL`. |
| RateOutOfRange(rateBps) | The rate is 0 or above 5000. |
| TermOutOfRange(termDays) | The term is 0 or above 365. |
| InstallmentsOutOfRange(installments) | The installment count is 0 or above 6. |
| LoanNotFound(loanId) | The id does not exist, including id 0. |
| LoanNotOpen(loanId) | `fund` on a loan that is not Open. |
| SelfFunding | The borrower tries to fund their own request. |
| LoanNotActive(loanId) | `repay`, `markDefaulted` or `nextInstallment` on a loan that is not Active. |
| LoanNotFunded(loanId) | `installmentDueAt` on a request that has no funding yet. |
| InstallmentOutOfRange(index, installments) | `installmentDueAt` with an index of 0 or above the installment count. |
| NotBorrower(caller, borrower) | `repay` called by someone other than the borrower. |
| Overpayment(amount, maxAllowed) | A payment is above what is left on the current installment. |
| NotOverdue(loanId, overdueAfter) | `markDefaulted` when the current installment is not yet more than 7 days overdue. `overdueAfter` is the last second at which the call still reverts. |
| UnexpectedTransferAmount(expected, received) | The receiver got another amount than the one sent. |

Token failures come from the token itself. With the mock token, a missing allowance reverts with `ERC20InsufficientAllowance(book, allowance, needed)` and a short balance with `ERC20InsufficientBalance(account, balance, needed)`.

## Mock token

The demo deployment uses `MockStablecoin`, an ERC-20 with 6 decimals. Anyone can call `mint(amount)` to get tokens for their own wallet, up to 1,000 tokens per call. An account holding `MINTER_ROLE` can call `mintTo(to, amount)`, up to 10,000 tokens per call. Both paths together can never put more than 10,000 tokens minted into one address. The role gives no power over any loan, and `LoanBook` does not import access control.

## Known limitations

- Two wallets controlled by one person can fund each other, and the public mint lets that person pay the interest. The contract only blocks the same address as lender and borrower. A testnet cannot prevent the rest, so the reputation logic in Phase 4 has to weigh other signals.
- A token that blocks or rejects transfers to the lender address makes repayment impossible and the loan can end in default. The deployment token is the plain mock. Read any other token before you deploy a book with it.
- Tokens that take a fee on transfer are rejected. `fund` and `repay` compare the receiver balance before and after the transfer and revert with `UnexpectedTransferAmount` when it differs.
- Tokens with transfer hooks (ERC-777 style) cannot re-enter the book. Every state-changing function carries a reentrancy guard and writes its state before it calls the token.
- Timestamps are set by validators within a small skew. The rules only use day scale logic (installments in days, a 7 day grace), so a skew of seconds does not change an outcome except for a payment sent in the very second of a due time.
- There is no way to cancel an open request in this ABI version. A cancel event would be a fifth event and would change the v0 event ABI.
- The grace period cannot be changed. To show a default in a demo, fund the loan at least 8 days before the demo gate or advance time in a test.

## Worked examples

### Standard loan with three installments

1000 tokens (`1000000000` base units) at 1000 bps for 90 days.

- Interest: `floor(1000000000 * 1000 * 90 / 3650000)` = 24657534.
- Total due: 1024657534.
- With N = 3: `base` = 341552511. Installments are 341552511, 341552511 and 341552512.
- Due times: 30, 60 and 90 days after funding.
- If installment 1 is paid on day 30 or earlier it counts as on time. Paid on day 31 it counts as late.
- If nothing is paid, anyone can mark the loan defaulted from the first second after day 37. The outstanding amount in `LoanDefaulted` is 1024657534.

### Example from the repayment ADR

100 tokens (`100000000`) at 1000 bps for 30 days with 2 installments.

- Interest: `floor(100000000 * 1000 * 30 / 3650000)` = 821917.
- Total due: 100821917.
- `base` = 50410958, so installment 1 is 50410958 and installment 2 is 50410959.
- Due times: 15 and 30 days after funding.

### Dust case

Principal 1 base unit at 1 bps for 1 day with 6 installments.

- Interest: `floor(1 * 1 * 1 / 3650000)` = 0, so the total due is 1.
- `base` = `floor(1 / 6)` = 0, so the current installment is number 6 from the start.
- One payment of 1 repays the loan. Installment 6 falls due one day after funding.
