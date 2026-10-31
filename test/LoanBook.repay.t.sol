// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {LoanBook} from "../src/LoanBook.sol";
import {LoanBookBase} from "./utils/LoanBookBase.sol";

/// @dev Shared helpers for the repayment and default tests. Expected values are computed here from
/// the documented rules and never read back from the contract under test.
abstract contract LifecycleBase is LoanBookBase {
    uint256 internal constant START = 1_800_000_000;
    // Total due of the standard loan: 1000e6 at 1000 bps for 90 days.
    uint256 internal constant TOTAL = 1_024_657_534;
    uint256 internal constant TERM = 90 days;

    function setUp() public virtual override {
        super.setUp();
        vm.warp(START);
    }

    /// @dev Requests and funds the standard loan at START.
    function _funded(uint8 installments) internal returns (uint256 loanId) {
        loanId = _request(installments);
        vm.prank(lender);
        book.fund(loanId);
    }

    /// @dev Requests and funds a loan with custom terms at the current time.
    function _fundedWith(uint256 amount, uint16 rate, uint32 termDays, uint8 installments)
        internal
        returns (uint256 loanId)
    {
        vm.prank(borrower);
        loanId = book.requestLoan(amount, rate, termDays, installments);
        vm.prank(lender);
        book.fund(loanId);
    }

    function _base(uint256 total, uint256 n) internal pure returns (uint256) {
        return total / n;
    }

    /// @dev Installment k (1 based) of a loan with the given total and count.
    function _installment(uint256 total, uint256 n, uint256 k) internal pure returns (uint256) {
        uint256 base = total / n;
        return k == n ? total - (n - 1) * base : base;
    }

    function _dueAt(uint256 fundedAt, uint256 termDays, uint256 n, uint256 k)
        internal
        pure
        returns (uint256)
    {
        return fundedAt + (k * termDays * 1 days) / n;
    }

    function _pay(uint256 loanId, uint256 amount) internal {
        vm.prank(borrower);
        book.repay(loanId, amount);
    }
}

contract LoanBookRepayTest is LifecycleBase {
    // ---------------------------------------------------------------- tracer

    function test_Repay_OnTimeMovesTokensAndEmits() public {
        uint256 id = _funded(3);
        uint256 amount = _installment(TOTAL, 3, 1);
        uint256 lenderBefore = token.balanceOf(lender);
        uint256 borrowerBefore = token.balanceOf(borrower);
        vm.warp(START + 10 days);

        vm.expectEmit(true, false, false, true, address(book));
        emit LoanRepaid(id, amount, true);
        _pay(id, amount);

        assertEq(token.balanceOf(lender) - lenderBefore, amount);
        assertEq(borrowerBefore - token.balanceOf(borrower), amount);
        assertEq(token.balanceOf(address(book)), 0);
        assertEq(book.getLoan(id).totalPaid, amount);
        assertEq(uint8(book.getLoan(id).status), uint8(LoanBook.Status.Active));

        LoanBook.Reputation memory rep = book.reputationOf(borrower);
        assertEq(rep.onTime, 1);
        assertEq(rep.late, 0);
        assertEq(rep.defaulted, 0);
    }

    // -------------------------------------------------------------- lateness

    function test_Repay_AtTheDueSecondIsOnTime() public {
        uint256 id = _funded(3);
        vm.warp(_dueAt(START, 90, 3, 1));

        vm.expectEmit(true, false, false, true, address(book));
        emit LoanRepaid(id, _installment(TOTAL, 3, 1), true);
        _pay(id, _installment(TOTAL, 3, 1));

        assertEq(book.reputationOf(borrower).onTime, 1);
        assertEq(book.reputationOf(borrower).late, 0);
    }

    function test_Repay_OneSecondAfterTheDueSecondIsLate() public {
        uint256 id = _funded(3);
        vm.warp(_dueAt(START, 90, 3, 1) + 1);

        vm.expectEmit(true, false, false, true, address(book));
        emit LoanRepaid(id, _installment(TOTAL, 3, 1), false);
        _pay(id, _installment(TOTAL, 3, 1));

        assertEq(book.reputationOf(borrower).onTime, 0);
        assertEq(book.reputationOf(borrower).late, 1);
    }

    function test_Repay_LatePaymentIsAcceptedAndMovesTokens() public {
        uint256 id = _funded(1);
        vm.warp(START + 90 days + 3 days);
        uint256 lenderBefore = token.balanceOf(lender);

        vm.expectEmit(true, false, false, true, address(book));
        emit LoanRepaid(id, TOTAL, false);
        _pay(id, TOTAL);

        assertEq(token.balanceOf(lender) - lenderBefore, TOTAL);
        assertEq(uint8(book.getLoan(id).status), uint8(LoanBook.Status.Repaid));
        assertEq(book.reputationOf(borrower).late, 1);
    }

    function test_Repay_UnpaidInstallmentOneStaysCurrentAfterInstallmentTwoIsDue() public {
        uint256 id = _funded(3);
        // Installment 2 is already due, but installment 1 is still unpaid and is the current one.
        vm.warp(_dueAt(START, 90, 3, 2) - 1);
        (uint256 index, uint256 dueAt, uint256 amountDue) = book.nextInstallment(id);
        assertEq(index, 1);
        assertEq(dueAt, _dueAt(START, 90, 3, 1));
        assertEq(amountDue, _installment(TOTAL, 3, 1));

        vm.expectEmit(true, false, false, true, address(book));
        emit LoanRepaid(id, amountDue, false);
        _pay(id, amountDue);
    }

    // ---------------------------------------------------------- installments

    function test_Repay_ThreeInstallmentsOfOneHundredAre33_33_34() public {
        uint256 id = _fundedWith(100, 1, 1, 3);
        assertEq(book.getLoan(id).totalDue, 100);

        (uint256 index,, uint256 amountDue) = book.nextInstallment(id);
        assertEq(index, 1);
        assertEq(amountDue, 33);
        _pay(id, 33);

        (index,, amountDue) = book.nextInstallment(id);
        assertEq(index, 2);
        assertEq(amountDue, 33);
        _pay(id, 33);

        (index,, amountDue) = book.nextInstallment(id);
        assertEq(index, 3);
        assertEq(amountDue, 34);
        _pay(id, 34);

        assertEq(uint8(book.getLoan(id).status), uint8(LoanBook.Status.Repaid));
        assertEq(token.balanceOf(address(book)), 0);
    }

    function test_Repay_SingleInstallmentLoanPaysTheWholeTotal() public {
        uint256 id = _funded(1);
        (uint256 index, uint256 dueAt, uint256 amountDue) = book.nextInstallment(id);
        assertEq(index, 1);
        assertEq(dueAt, START + 90 days);
        assertEq(amountDue, TOTAL);

        vm.expectRevert(abi.encodeWithSelector(LoanBook.Overpayment.selector, TOTAL + 1, TOTAL));
        _pay(id, TOTAL + 1);

        _pay(id, TOTAL);
        assertEq(uint8(book.getLoan(id).status), uint8(LoanBook.Status.Repaid));
    }

    function test_Repay_SixInstallmentsOnTimeSumToTheTotal() public {
        uint256 id = _funded(6);
        uint256 lenderBefore = token.balanceOf(lender);
        uint256 sum;

        for (uint256 k = 1; k <= 6; k++) {
            vm.warp(_dueAt(START, 90, 6, k));
            (uint256 index, uint256 dueAt, uint256 amountDue) = book.nextInstallment(id);
            assertEq(index, k);
            assertEq(dueAt, _dueAt(START, 90, 6, k));
            assertEq(amountDue, _installment(TOTAL, 6, k));
            _pay(id, amountDue);
            sum += amountDue;
            assertEq(token.balanceOf(address(book)), 0);
        }

        assertEq(sum, TOTAL);
        assertEq(token.balanceOf(lender) - lenderBefore, TOTAL);
        assertEq(uint8(book.getLoan(id).status), uint8(LoanBook.Status.Repaid));
        assertEq(book.reputationOf(borrower).onTime, 6);
        assertEq(book.reputationOf(borrower).late, 0);
    }

    function test_Repay_LastInstallmentAbsorbsTheRemainder() public {
        uint256 id = _funded(3);
        uint256 base = _base(TOTAL, 3);
        uint256 last = _installment(TOTAL, 3, 3);
        assertGt(last, base);
        assertLe(last - base, 2);

        _pay(id, base);
        _pay(id, base);
        (uint256 index,, uint256 amountDue) = book.nextInstallment(id);
        assertEq(index, 3);
        assertEq(amountDue, last);
    }

    function test_Repay_PartialPaymentsInsideTheCurrentInstallment() public {
        uint256 id = _funded(2);
        uint256 first = _installment(TOTAL, 2, 1);
        uint256 half = first / 2;

        vm.expectEmit(true, false, false, true, address(book));
        emit LoanRepaid(id, half, true);
        _pay(id, half);

        (uint256 index,, uint256 amountDue) = book.nextInstallment(id);
        assertEq(index, 1);
        assertEq(amountDue, first - half);

        _pay(id, first - half);
        (index,, amountDue) = book.nextInstallment(id);
        assertEq(index, 2);
        assertEq(amountDue, _installment(TOTAL, 2, 2));

        // One signal per payment, not one per installment.
        assertEq(book.reputationOf(borrower).onTime, 2);
    }

    function test_Repay_OverpayingTheCurrentInstallmentReverts() public {
        uint256 id = _funded(2);
        uint256 first = _installment(TOTAL, 2, 1);

        vm.expectRevert(abi.encodeWithSelector(LoanBook.Overpayment.selector, first + 1, first));
        _pay(id, first + 1);
    }

    function test_Repay_APaymentNeverSpansTwoInstallments() public {
        uint256 id = _funded(3);
        uint256 base = _base(TOTAL, 3);
        _pay(id, base - 10);

        // The sum of the next two installments is more than what is left on installment 1.
        vm.expectRevert(abi.encodeWithSelector(LoanBook.Overpayment.selector, base + 1, 10));
        _pay(id, base + 1);
    }

    function test_Repay_OverpayWithUint256MaxReverts() public {
        uint256 id = _funded(2);
        vm.expectRevert(
            abi.encodeWithSelector(
                LoanBook.Overpayment.selector, type(uint256).max, _installment(TOTAL, 2, 1)
            )
        );
        _pay(id, type(uint256).max);
    }

    function test_Repay_ZeroAmountReverts() public {
        uint256 id = _funded(2);
        vm.expectRevert(LoanBook.ZeroAmount.selector);
        _pay(id, 0);
    }

    function test_Repay_DustPrincipalOneWithSixInstallments() public {
        uint256 id = _fundedWith(1, 1, 1, 6);
        assertEq(book.getLoan(id).totalDue, 1);

        (uint256 index, uint256 dueAt, uint256 amountDue) = book.nextInstallment(id);
        assertEq(index, 6);
        assertEq(dueAt, START + 1 days);
        assertEq(amountDue, 1);

        _pay(id, 1);
        assertEq(uint8(book.getLoan(id).status), uint8(LoanBook.Status.Repaid));
        assertEq(token.balanceOf(address(book)), 0);
    }

    function test_Repay_DustTotalSmallerThanInstallmentCount() public {
        // Total 5 with 6 installments: base is 0 and the last installment carries everything.
        uint256 id = _fundedWith(5, 1, 1, 6);
        assertEq(book.getLoan(id).totalDue, 5);
        (uint256 index,, uint256 amountDue) = book.nextInstallment(id);
        assertEq(index, 6);
        assertEq(amountDue, 5);

        _pay(id, 2);
        (index,, amountDue) = book.nextInstallment(id);
        assertEq(index, 6);
        assertEq(amountDue, 3);
        _pay(id, 3);
        assertEq(uint8(book.getLoan(id).status), uint8(LoanBook.Status.Repaid));
    }

    function test_Repay_AdrExampleHasInterest821917() public {
        uint256 id = _fundedWith(100e6, 1000, 30, 2);
        LoanBook.Loan memory loan = book.getLoan(id);
        assertEq(loan.totalDue - loan.principal, 821_917);
        assertEq(loan.totalDue, 100_821_917);

        (uint256 index,, uint256 amountDue) = book.nextInstallment(id);
        assertEq(index, 1);
        assertEq(amountDue, 50_410_958);
        _pay(id, 50_410_958);

        (index,, amountDue) = book.nextInstallment(id);
        assertEq(index, 2);
        assertEq(amountDue, 50_410_959);
        _pay(id, 50_410_959);

        assertEq(uint8(book.getLoan(id).status), uint8(LoanBook.Status.Repaid));
    }

    function test_Repay_OneDayLoanExample() public {
        uint256 id = _fundedWith(100e6, 1000, 1, 2);
        assertEq(book.getLoan(id).totalDue, 100_027_397);
        (,, uint256 amountDue) = book.nextInstallment(id);
        assertEq(amountDue, 50_013_698);
        _pay(id, 50_013_698);
        (,, amountDue) = book.nextInstallment(id);
        assertEq(amountDue, 50_013_699);
    }

    // ------------------------------------------------------------ who pays

    function test_Repay_StrangerRevertsEvenWithAnApprovedAllowance() public {
        uint256 id = _funded(2);
        uint256 amount = _installment(TOTAL, 2, 1);

        // The borrower approves a finite amount, so a spend would visibly lower it.
        vm.prank(borrower);
        token.approve(address(book), 500e6);

        address stranger = makeAddr("stranger");
        token.mintTo(stranger, 100e6);
        vm.prank(stranger);
        token.approve(address(book), type(uint256).max);

        uint256 borrowerBalance = token.balanceOf(borrower);
        uint256 lenderBalance = token.balanceOf(lender);

        vm.expectRevert(abi.encodeWithSelector(LoanBook.NotBorrower.selector, stranger, borrower));
        vm.prank(stranger);
        book.repay(id, amount);

        assertEq(token.balanceOf(borrower), borrowerBalance);
        assertEq(token.balanceOf(lender), lenderBalance);
        assertEq(token.balanceOf(stranger), 100e6);
        assertEq(token.allowance(borrower, address(book)), 500e6);
        assertEq(book.getLoan(id).totalPaid, 0);
    }

    function test_Repay_LenderCannotRepayEither() public {
        uint256 id = _funded(1);
        vm.expectRevert(abi.encodeWithSelector(LoanBook.NotBorrower.selector, lender, borrower));
        vm.prank(lender);
        book.repay(id, 1);
    }

    function test_Repay_FailsWithoutAllowanceAndKeepsState() public {
        uint256 id = _funded(1);
        vm.prank(borrower);
        token.approve(address(book), 0);

        vm.expectRevert();
        _pay(id, TOTAL);

        assertEq(book.getLoan(id).totalPaid, 0);
        assertEq(book.reputationOf(borrower).onTime, 0);
    }

    // ------------------------------------------------------------- statuses

    function test_Repay_UnknownIdReverts() public {
        vm.expectRevert(abi.encodeWithSelector(LoanBook.LoanNotFound.selector, 42));
        _pay(42, 1);
    }

    function test_Repay_OpenLoanReverts() public {
        uint256 id = _request(2);
        vm.expectRevert(abi.encodeWithSelector(LoanBook.LoanNotActive.selector, id));
        _pay(id, 1);
    }

    function test_Repay_RepaidLoanReverts() public {
        uint256 id = _funded(1);
        _pay(id, TOTAL);
        vm.expectRevert(abi.encodeWithSelector(LoanBook.LoanNotActive.selector, id));
        _pay(id, 1);
    }

    function test_Repay_RepaidExactlyWhenTotalPaidEqualsTotalDue() public {
        uint256 id = _funded(2);
        _pay(id, _installment(TOTAL, 2, 1));
        assertEq(uint8(book.getLoan(id).status), uint8(LoanBook.Status.Active));

        _pay(id, _installment(TOTAL, 2, 2) - 1);
        assertEq(uint8(book.getLoan(id).status), uint8(LoanBook.Status.Active));

        _pay(id, 1);
        LoanBook.Loan memory loan = book.getLoan(id);
        assertEq(uint8(loan.status), uint8(LoanBook.Status.Repaid));
        assertEq(loan.totalPaid, loan.totalDue);
    }

    // ---------------------------------------------------------------- views

    function test_NextInstallment_RevertsForOpenAndRepaidLoans() public {
        uint256 open = _request(2);
        vm.expectRevert(abi.encodeWithSelector(LoanBook.LoanNotActive.selector, open));
        book.nextInstallment(open);

        uint256 repaid = _funded(1);
        _pay(repaid, TOTAL);
        vm.expectRevert(abi.encodeWithSelector(LoanBook.LoanNotActive.selector, repaid));
        book.nextInstallment(repaid);
    }

    function test_NextInstallment_UnknownIdReverts() public {
        vm.expectRevert(abi.encodeWithSelector(LoanBook.LoanNotFound.selector, 9));
        book.nextInstallment(9);
    }

    function test_InstallmentDueAt_ReturnsTheScheduleForEveryIndex() public {
        uint256 id = _funded(6);
        for (uint256 k = 1; k <= 6; k++) {
            assertEq(book.installmentDueAt(id, k), _dueAt(START, 90, 6, k));
        }
        // Installment N falls exactly on the due date announced in LoanFunded.
        assertEq(book.installmentDueAt(id, 6), book.dueDateOf(uint64(START), 90));
    }

    function test_InstallmentDueAt_RevertsOutsideTheRange() public {
        uint256 id = _funded(3);
        vm.expectRevert(abi.encodeWithSelector(LoanBook.InstallmentOutOfRange.selector, 0, 3));
        book.installmentDueAt(id, 0);
        vm.expectRevert(abi.encodeWithSelector(LoanBook.InstallmentOutOfRange.selector, 4, 3));
        book.installmentDueAt(id, 4);
    }

    function test_InstallmentDueAt_RevertsForAnOpenLoan() public {
        uint256 id = _request(3);
        vm.expectRevert(abi.encodeWithSelector(LoanBook.LoanNotFunded.selector, id));
        book.installmentDueAt(id, 1);
    }

    function test_InstallmentDueAt_UnknownIdReverts() public {
        vm.expectRevert(abi.encodeWithSelector(LoanBook.LoanNotFound.selector, 5));
        book.installmentDueAt(5, 1);
    }

    function test_InstallmentDueAt_WorksAfterTheLoanIsRepaid() public {
        uint256 id = _funded(1);
        _pay(id, TOTAL);
        assertEq(book.installmentDueAt(id, 1), START + 90 days);
    }

    // ------------------------------------------------------------ counters

    function test_Reputation_StartsAtZero() public {
        LoanBook.Reputation memory rep = book.reputationOf(makeAddr("nobody"));
        assertEq(rep.onTime, 0);
        assertEq(rep.late, 0);
        assertEq(rep.defaulted, 0);
    }

    function test_Reputation_OneSignalPerPaymentMixedOnTimeAndLate() public {
        uint256 id = _funded(2);
        uint256 first = _installment(TOTAL, 2, 1);

        _pay(id, first / 2);
        vm.warp(_dueAt(START, 90, 2, 1) + 1);
        _pay(id, first - first / 2);
        vm.warp(_dueAt(START, 90, 2, 2) - 1);
        _pay(id, _installment(TOTAL, 2, 2));

        LoanBook.Reputation memory rep = book.reputationOf(borrower);
        assertEq(rep.onTime, 2);
        assertEq(rep.late, 1);
        assertEq(rep.defaulted, 0);
    }

    function test_Reputation_CountersBelongToTheBorrowerOnly() public {
        uint256 id = _funded(1);
        _pay(id, TOTAL);
        LoanBook.Reputation memory lenderRep = book.reputationOf(lender);
        assertEq(lenderRep.onTime + lenderRep.late + lenderRep.defaulted, 0);
    }

    function test_Reputation_RevertedPaymentsLeaveCountersAlone() public {
        uint256 id = _funded(2);
        vm.expectRevert(LoanBook.ZeroAmount.selector);
        _pay(id, 0);
        vm.expectRevert();
        _pay(id, type(uint256).max);
        LoanBook.Reputation memory rep = book.reputationOf(borrower);
        assertEq(rep.onTime + rep.late + rep.defaulted, 0);
    }

    // ----------------------------------------------------------- immutability

    function test_Immutability_FixedFieldsNeverChangeAcrossRepayments() public {
        uint256 id = _funded(3);
        LoanBook.Loan memory snapshot = book.getLoan(id);

        for (uint256 k = 1; k <= 3; k++) {
            vm.warp(_dueAt(START, 90, 3, k) + (k == 2 ? 2 days : 0));
            _pay(id, _installment(TOTAL, 3, k));

            LoanBook.Loan memory now_ = book.getLoan(id);
            assertEq(now_.borrower, snapshot.borrower);
            assertEq(now_.interestRateBps, snapshot.interestRateBps);
            assertEq(now_.termDays, snapshot.termDays);
            assertEq(now_.installments, snapshot.installments);
            assertEq(now_.principal, snapshot.principal);
            assertEq(now_.lender, snapshot.lender);
            assertEq(now_.fundedAt, snapshot.fundedAt);
            assertEq(now_.totalDue, snapshot.totalDue);
        }
    }

    function test_Repay_RepaymentsOnTwoLoansStayIndependent() public {
        uint256 a = _funded(1);
        uint256 b = _fundedWith(50e6, 500, 30, 2);

        _pay(a, TOTAL);
        assertEq(uint8(book.getLoan(a).status), uint8(LoanBook.Status.Repaid));
        assertEq(uint8(book.getLoan(b).status), uint8(LoanBook.Status.Active));
        assertEq(book.getLoan(b).totalPaid, 0);
    }
}

contract LoanBookDefaultTest is LifecycleBase {
    // ---------------------------------------------------------------- tracer

    function test_MarkDefaulted_OneSecondAfterGraceWorksForAnyCaller() public {
        uint256 id = _funded(1);
        uint256 dueAt = START + 90 days;
        vm.warp(dueAt + 7 days + 1);

        address keeper = makeAddr("keeper");
        vm.expectEmit(true, true, false, true, address(book));
        emit LoanDefaulted(id, borrower, TOTAL);
        vm.prank(keeper);
        book.markDefaulted(id);

        assertEq(uint8(book.getLoan(id).status), uint8(LoanBook.Status.Defaulted));
        LoanBook.Reputation memory rep = book.reputationOf(borrower);
        assertEq(rep.defaulted, 1);
        assertEq(rep.onTime, 0);
        assertEq(rep.late, 0);
    }

    // ------------------------------------------------------------ boundary

    function test_MarkDefaulted_ExactlySevenDaysAfterRevertsNotOverdue() public {
        uint256 id = _funded(1);
        uint256 dueAt = START + 90 days;
        vm.warp(dueAt + 7 days);

        vm.expectRevert(abi.encodeWithSelector(LoanBook.NotOverdue.selector, id, dueAt + 7 days));
        book.markDefaulted(id);
        assertEq(uint8(book.getLoan(id).status), uint8(LoanBook.Status.Active));
    }

    function test_MarkDefaulted_BeforeTheDueDateRevertsNotOverdue() public {
        uint256 id = _funded(3);
        uint256 dueAt = _dueAt(START, 90, 3, 1);
        vm.warp(dueAt - 1);
        vm.expectRevert(abi.encodeWithSelector(LoanBook.NotOverdue.selector, id, dueAt + 7 days));
        book.markDefaulted(id);
    }

    function test_MarkDefaulted_RightAfterTheDueDateRevertsNotOverdue() public {
        uint256 id = _funded(1);
        uint256 dueAt = START + 90 days;
        vm.warp(dueAt + 1);
        vm.expectRevert(abi.encodeWithSelector(LoanBook.NotOverdue.selector, id, dueAt + 7 days));
        book.markDefaulted(id);
    }

    function test_MarkDefaulted_UsesTheCurrentInstallment() public {
        uint256 id = _funded(3);
        uint256 base = _installment(TOTAL, 3, 1);
        vm.warp(_dueAt(START, 90, 3, 1));
        _pay(id, base);

        // Installment 1 is settled, so only installment 2 counts.
        uint256 dueAt2 = _dueAt(START, 90, 3, 2);
        vm.warp(_dueAt(START, 90, 3, 1) + 7 days + 1);
        vm.expectRevert(abi.encodeWithSelector(LoanBook.NotOverdue.selector, id, dueAt2 + 7 days));
        book.markDefaulted(id);

        vm.warp(dueAt2 + 7 days);
        vm.expectRevert(abi.encodeWithSelector(LoanBook.NotOverdue.selector, id, dueAt2 + 7 days));
        book.markDefaulted(id);

        vm.warp(dueAt2 + 7 days + 1);
        vm.expectEmit(true, true, false, true, address(book));
        emit LoanDefaulted(id, borrower, TOTAL - base);
        book.markDefaulted(id);
    }

    function test_MarkDefaulted_PartialPaymentDoesNotStopTheDefault() public {
        uint256 id = _funded(2);
        uint256 dueAt1 = _dueAt(START, 90, 2, 1);
        vm.warp(dueAt1);
        _pay(id, 1_000_000);

        vm.warp(dueAt1 + 7 days + 1);
        vm.expectEmit(true, true, false, true, address(book));
        emit LoanDefaulted(id, borrower, TOTAL - 1_000_000);
        book.markDefaulted(id);
    }

    function test_MarkDefaulted_KeepsOnTimeCountersEarned() public {
        uint256 id = _funded(2);
        vm.warp(_dueAt(START, 90, 2, 1));
        _pay(id, _installment(TOTAL, 2, 1));
        vm.warp(_dueAt(START, 90, 2, 2) + 7 days + 1);
        book.markDefaulted(id);

        LoanBook.Reputation memory rep = book.reputationOf(borrower);
        assertEq(rep.onTime, 1);
        assertEq(rep.late, 0);
        assertEq(rep.defaulted, 1);
    }

    function test_MarkDefaulted_MovesNoTokens() public {
        uint256 id = _funded(1);
        vm.warp(START + 90 days + 8 days);
        uint256 lenderBefore = token.balanceOf(lender);
        uint256 borrowerBefore = token.balanceOf(borrower);

        book.markDefaulted(id);

        assertEq(token.balanceOf(lender), lenderBefore);
        assertEq(token.balanceOf(borrower), borrowerBefore);
        assertEq(token.balanceOf(address(book)), 0);
    }

    // ------------------------------------------------------------ statuses

    function test_MarkDefaulted_SecondCallReverts() public {
        uint256 id = _funded(1);
        vm.warp(START + 90 days + 8 days);
        book.markDefaulted(id);

        vm.expectRevert(abi.encodeWithSelector(LoanBook.LoanNotActive.selector, id));
        book.markDefaulted(id);
        assertEq(book.reputationOf(borrower).defaulted, 1);
    }

    function test_MarkDefaulted_OpenLoanReverts() public {
        uint256 id = _request(1);
        vm.warp(START + 365 days);
        vm.expectRevert(abi.encodeWithSelector(LoanBook.LoanNotActive.selector, id));
        book.markDefaulted(id);
    }

    function test_MarkDefaulted_RepaidLoanReverts() public {
        uint256 id = _funded(1);
        _pay(id, TOTAL);
        vm.warp(START + 365 days);
        vm.expectRevert(abi.encodeWithSelector(LoanBook.LoanNotActive.selector, id));
        book.markDefaulted(id);
    }

    function test_MarkDefaulted_UnknownIdReverts() public {
        vm.expectRevert(abi.encodeWithSelector(LoanBook.LoanNotFound.selector, 3));
        book.markDefaulted(3);
    }

    function test_Repay_AfterDefaultRevertsLoanNotActive() public {
        uint256 id = _funded(1);
        vm.warp(START + 90 days + 8 days);
        book.markDefaulted(id);

        vm.expectRevert(abi.encodeWithSelector(LoanBook.LoanNotActive.selector, id));
        _pay(id, 1);
    }

    function test_NextInstallment_AfterDefaultRevertsLoanNotActive() public {
        uint256 id = _funded(1);
        vm.warp(START + 90 days + 8 days);
        book.markDefaulted(id);

        vm.expectRevert(abi.encodeWithSelector(LoanBook.LoanNotActive.selector, id));
        book.nextInstallment(id);
    }

    function test_GracePeriodIsSevenDays() public view {
        assertEq(book.GRACE_PERIOD(), 7 days);
    }
}
