// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {LoanBook} from "../src/LoanBook.sol";
import {LoanBookBase} from "./utils/LoanBookBase.sol";

/// @notice Property tests for the interest math, the installment schedule, the time boundaries and
/// the request ranges. Every expected value comes from a reference written in this file from the
/// documented rules, never from the contract under test. Large balances use `deal`, so the
/// production mint caps stay as they are.
contract LoanBookFuzzTest is LoanBookBase {
    uint256 private constant START = 1_800_000_000;
    uint256 private constant MAX_PRINCIPAL = type(uint128).max / 2;
    uint256 private constant GRACE = 7 days;

    function setUp() public override {
        super.setUp();
        vm.warp(START);
    }

    // ------------------------------------------------------------------ interest

    function testFuzz_TotalDueBounds(uint256 principal, uint16 rate, uint32 term) public view {
        principal = bound(principal, 1, MAX_PRINCIPAL);
        rate = uint16(bound(rate, 1, 5000));
        term = uint32(bound(term, 1, 365));

        uint256 total = book.totalDueFor(principal, rate, term);

        assertGe(total, principal);
        assertLe(total, principal + principal / 2);
        assertEq(total, _refTotal(principal, rate, term));
    }

    // ------------------------------------------------------------------ installments

    function testFuzz_InstallmentsSumToTotal(uint256 principal, uint16 rate, uint32 term, uint8 n)
        public
    {
        principal = bound(principal, 1, 1_000_000e6);
        rate = uint16(bound(rate, 1, 5000));
        term = uint32(bound(term, 1, 365));
        n = uint8(bound(n, 1, 6));
        (uint256 id, uint256 total) = _funded(principal, rate, term, n);
        assertEq(book.getLoan(id).totalDue, total);

        uint256 base = total / n;
        uint256 paid;
        for (uint256 k = 1; k <= n; ++k) {
            uint256 amount = k == n ? total - (n - 1) * base : base;
            if (amount == 0) continue;
            _pay(id, amount);
            paid += amount;
        }

        assertEq(paid, total);
        assertEq(book.getLoan(id).totalPaid, total);
        assertEq(uint8(book.getLoan(id).status), uint8(LoanBook.Status.Repaid));
    }

    function testFuzz_TinyPrincipalEveryN(uint256 principal, uint16 rate, uint32 term) public {
        principal = bound(principal, 1, 100);
        rate = uint16(bound(rate, 1, 5000));
        term = uint32(bound(term, 1, 365));

        for (uint256 n = 1; n <= 6; ++n) {
            (uint256 id, uint256 total) = _funded(principal, rate, term, uint8(n));
            uint256 paid;
            uint256 payments;
            while (book.getLoan(id).status == LoanBook.Status.Active) {
                (,, uint256 due) = book.nextInstallment(id);
                assertGt(due, 0);
                _pay(id, due);
                paid += due;
                ++payments;
                assertLe(payments, n);
            }
            assertEq(paid, total);
            assertEq(book.getLoan(id).totalPaid, total);
            assertEq(uint8(book.getLoan(id).status), uint8(LoanBook.Status.Repaid));
        }
    }

    function testFuzz_RepayAboveRemainingReverts(
        uint256 principal,
        uint8 n,
        uint8 prior,
        uint256 extra
    ) public {
        principal = bound(principal, 6, 1_000_000e6);
        n = uint8(bound(n, 1, 6));
        prior = uint8(bound(prior, 0, n - 1));
        extra = bound(extra, 1, type(uint128).max);
        (uint256 id,) = _funded(principal, 1000, 90, n);
        _payFirst(id, prior);
        (,, uint256 remaining) = book.nextInstallment(id);
        uint256 paidBefore = book.getLoan(id).totalPaid;

        vm.expectRevert(
            abi.encodeWithSelector(LoanBook.Overpayment.selector, remaining + extra, remaining)
        );
        vm.prank(borrower);
        book.repay(id, remaining + extra);

        assertEq(book.getLoan(id).totalPaid, paidBefore);
    }

    function testFuzz_RepayWithinRemainingSucceeds(
        uint256 principal,
        uint8 n,
        uint8 prior,
        uint256 amount
    ) public {
        principal = bound(principal, 6, 1_000_000e6);
        n = uint8(bound(n, 1, 6));
        prior = uint8(bound(prior, 0, n - 1));
        (uint256 id,) = _funded(principal, 1000, 90, n);
        _payFirst(id, prior);
        (,, uint256 remaining) = book.nextInstallment(id);
        amount = bound(amount, 1, remaining);
        uint256 paidBefore = book.getLoan(id).totalPaid;
        uint256 lenderBefore = token.balanceOf(lender);

        _pay(id, amount);

        assertEq(book.getLoan(id).totalPaid, paidBefore + amount);
        assertEq(token.balanceOf(lender) - lenderBefore, amount);
        assertEq(token.balanceOf(address(book)), 0);
    }

    // ------------------------------------------------------------------ time boundaries

    /// @dev A payment is on time exactly when it arrives at or before the due time of the current
    /// installment. The tight mode puts the offset within three seconds of the boundary.
    function testFuzz_OnTimeBoundary(
        uint256 principal,
        uint8 n,
        uint8 prior,
        int256 rawOffset,
        bool tight
    ) public {
        principal = bound(principal, 6, 1_000_000e6);
        n = uint8(bound(n, 1, 6));
        prior = uint8(bound(prior, 0, n - 1));
        (uint256 id,) = _funded(principal, 1000, 90, n);
        _payFirst(id, prior);
        (, uint256 dueAt, uint256 due) = book.nextInstallment(id);
        int256 offset =
            tight ? bound(rawOffset, -3, 3) : bound(rawOffset, -int256(3 days), int256(6 days));
        bool expectOnTime = offset <= 0;
        vm.warp(uint256(int256(dueAt) + offset));

        vm.expectEmit(true, false, false, true, address(book));
        emit LoanRepaid(id, due, expectOnTime);
        _pay(id, due);

        LoanBook.Reputation memory rep = book.reputationOf(borrower);
        // the prior payments were all made at the funding time, so they were on time
        assertEq(rep.onTime, prior + (expectOnTime ? 1 : 0));
        assertEq(rep.late, expectOnTime ? 0 : 1);
        assertEq(rep.defaulted, 0);
    }

    /// @dev The loan can be marked defaulted exactly when the time is strictly after the due time
    /// plus seven days. At the second of the boundary it still reverts.
    function testFuzz_DefaultBoundary(
        uint256 principal,
        uint8 n,
        uint8 prior,
        int256 rawOffset,
        bool tight
    ) public {
        principal = bound(principal, 6, 1_000_000e6);
        n = uint8(bound(n, 1, 6));
        prior = uint8(bound(prior, 0, n - 1));
        (uint256 id,) = _funded(principal, 1000, 90, n);
        _payFirst(id, prior);
        (, uint256 dueAt,) = book.nextInstallment(id);
        uint256 threshold = dueAt + GRACE;
        int256 offset =
            tight ? bound(rawOffset, -3, 3) : bound(rawOffset, -int256(8 days), int256(8 days));
        uint256 ts = uint256(int256(threshold) + offset);
        vm.warp(ts);

        if (ts > threshold) {
            book.markDefaulted(id);
            assertEq(uint8(book.getLoan(id).status), uint8(LoanBook.Status.Defaulted));
            assertEq(book.reputationOf(borrower).defaulted, 1);
        } else {
            vm.expectRevert(abi.encodeWithSelector(LoanBook.NotOverdue.selector, id, threshold));
            book.markDefaulted(id);
            assertEq(uint8(book.getLoan(id).status), uint8(LoanBook.Status.Active));
            assertEq(book.reputationOf(borrower).defaulted, 0);
        }
    }

    // ------------------------------------------------------------------ request ranges

    /// @dev All four inputs are free. The mask forces some of them into their valid range so that
    /// every check of the documented order (amount zero, amount too large, rate, term,
    /// installments) is reached with the earlier ones passing.
    function testFuzz_RequestRanges(
        uint256 amount,
        uint16 rate,
        uint32 term,
        uint8 installments,
        uint8 mask
    ) public {
        if (mask & 1 != 0) amount = bound(amount, 1, MAX_PRINCIPAL);
        if (mask & 2 != 0) rate = uint16(bound(rate, 1, 5000));
        if (mask & 4 != 0) term = uint32(bound(term, 1, 365));
        if (mask & 8 != 0) installments = uint8(bound(installments, 1, 6));

        bytes memory expected;
        if (amount == 0) {
            expected = abi.encodeWithSelector(LoanBook.ZeroAmount.selector);
        } else if (amount > MAX_PRINCIPAL) {
            expected =
                abi.encodeWithSelector(LoanBook.AmountTooLarge.selector, amount, MAX_PRINCIPAL);
        } else if (rate == 0 || rate > 5000) {
            expected = abi.encodeWithSelector(LoanBook.RateOutOfRange.selector, uint256(rate));
        } else if (term == 0 || term > 365) {
            expected = abi.encodeWithSelector(LoanBook.TermOutOfRange.selector, uint256(term));
        } else if (installments == 0 || installments > 6) {
            expected = abi.encodeWithSelector(
                LoanBook.InstallmentsOutOfRange.selector, uint256(installments)
            );
        }

        if (expected.length > 0) {
            vm.expectRevert(expected);
            vm.prank(borrower);
            book.requestLoan(amount, rate, term, installments);
            assertEq(book.loanCount(), 0);
        } else {
            vm.prank(borrower);
            uint256 id = book.requestLoan(amount, rate, term, installments);
            assertEq(id, 1);
            LoanBook.Loan memory loan = book.getLoan(id);
            assertEq(loan.borrower, borrower);
            assertEq(loan.principal, amount);
            assertEq(loan.interestRateBps, rate);
            assertEq(loan.termDays, term);
            assertEq(loan.installments, installments);
            assertEq(uint8(loan.status), uint8(LoanBook.Status.Open));
        }
    }

    // ------------------------------------------------------------------ token movement

    function testFuzz_FundAndRepayConserveTokens(
        uint256 principal,
        uint16 rate,
        uint32 term,
        uint8 n,
        uint256 amount
    ) public {
        principal = bound(principal, 1, MAX_PRINCIPAL);
        rate = uint16(bound(rate, 1, 5000));
        term = uint32(bound(term, 1, 365));
        n = uint8(bound(n, 1, 6));
        uint256 total = _refTotal(principal, rate, term);
        deal(address(token), lender, principal);
        deal(address(token), borrower, total);
        uint256 sumBefore = token.balanceOf(lender) + token.balanceOf(borrower);

        vm.prank(borrower);
        uint256 id = book.requestLoan(principal, rate, term, n);
        vm.prank(lender);
        book.fund(id);
        assertEq(token.balanceOf(lender) + token.balanceOf(borrower), sumBefore);
        assertEq(token.balanceOf(address(book)), 0);

        (,, uint256 remaining) = book.nextInstallment(id);
        amount = bound(amount, 1, remaining);
        _pay(id, amount);

        assertEq(token.balanceOf(lender) + token.balanceOf(borrower), sumBefore);
        assertEq(token.balanceOf(address(book)), 0);
    }

    function testFuzz_StrangerCannotRepay(address caller, uint256 amount) public {
        vm.assume(caller != borrower);
        (uint256 id,) = _funded(P, 1000, 90, 3);
        uint256 callerBalance = token.balanceOf(caller);
        uint256 lenderBalance = token.balanceOf(lender);

        vm.expectRevert(abi.encodeWithSelector(LoanBook.NotBorrower.selector, caller, borrower));
        vm.prank(caller);
        book.repay(id, amount);

        assertEq(token.balanceOf(caller), callerBalance);
        assertEq(token.balanceOf(lender), lenderBalance);
        assertEq(book.getLoan(id).totalPaid, 0);
    }

    // ------------------------------------------------------------------ helpers

    /// @dev Reference for the total due, two chained floor divisions as the documentation words it.
    function _refTotal(uint256 principal, uint256 rate, uint256 term)
        private
        pure
        returns (uint256)
    {
        return principal + ((principal * rate * term) / 365) / 10_000;
    }

    /// @dev Requests and funds a loan, and gives the borrower exactly what the whole debt costs.
    function _funded(uint256 principal, uint16 rate, uint32 term, uint8 n)
        private
        returns (uint256 id, uint256 total)
    {
        total = _refTotal(principal, rate, term);
        vm.prank(borrower);
        id = book.requestLoan(principal, rate, term, n);
        deal(address(token), lender, principal);
        vm.prank(lender);
        book.fund(id);
        deal(address(token), borrower, total);
    }

    function _pay(uint256 id, uint256 amount) private {
        vm.prank(borrower);
        book.repay(id, amount);
    }

    /// @dev Pays the next installment in full, count times, at the current time.
    function _payFirst(uint256 id, uint256 count) private {
        for (uint256 i; i < count; ++i) {
            (,, uint256 due) = book.nextInstallment(id);
            _pay(id, due);
        }
    }
}
