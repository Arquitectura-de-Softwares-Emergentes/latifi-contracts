// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {LoanBook} from "../src/LoanBook.sol";
import {LoanBookBase} from "./utils/LoanBookBase.sol";

contract LoanBookFundTest is LoanBookBase {
    // ---------------------------------------------------------------- tracer

    function test_Fund_MovesPrincipalActivatesAndEmits() public {
        uint256 loanId = _request(3);
        uint256 lenderBefore = token.balanceOf(lender);
        uint256 borrowerBefore = token.balanceOf(borrower);

        vm.warp(1_800_000_000);
        uint64 fundedAt = uint64(block.timestamp);
        uint64 dueDate = fundedAt + 90 days;

        vm.expectEmit(true, true, true, true, address(book));
        emit LoanFunded(loanId, lender, borrower, P, fundedAt, dueDate);

        vm.prank(lender);
        book.fund(loanId);

        assertEq(lenderBefore - token.balanceOf(lender), P);
        assertEq(token.balanceOf(borrower) - borrowerBefore, P);
        assertEq(token.balanceOf(address(book)), 0);

        LoanBook.Loan memory loan = book.getLoan(loanId);
        assertEq(uint8(loan.status), uint8(LoanBook.Status.Active));
        assertEq(loan.lender, lender);
        assertEq(loan.fundedAt, fundedAt);
        assertEq(loan.totalDue, 1_024_657_534);
        assertEq(loan.totalPaid, 0);
    }

    // ------------------------------------------------------------- total due

    function test_TotalDue_ThousandTokensNinetyDays() public view {
        assertEq(book.totalDueFor(1_000e6, 1000, 90), 1_024_657_534);
    }

    function test_TotalDue_AdrExampleThirtyDays() public view {
        assertEq(book.totalDueFor(100e6, 1000, 30), 100_821_917);
    }

    function test_TotalDue_OneDay() public view {
        assertEq(book.totalDueFor(100e6, 1000, 1), 100_027_397);
    }

    function test_TotalDue_StoredAtFundingMatchesTheFormula() public {
        vm.prank(borrower);
        uint256 loanId = book.requestLoan(100e6, 1000, 30, 2);
        vm.prank(lender);
        book.fund(loanId);
        assertEq(book.getLoan(loanId).totalDue, 100_821_917);
    }

    function test_TotalDue_FloorsTheInterest() public view {
        // 1 * 1 * 1 / 3650000 is zero, so the borrower owes only the principal.
        assertEq(book.totalDueFor(1, 1, 1), 1);
        // The smallest product that reaches one base unit of interest.
        assertEq(book.totalDueFor(3_650_000, 1, 1), 3_650_001);
        assertEq(book.totalDueFor(3_649_999, 1, 1), 3_649_999);
    }

    // ---------------------------------------------------------------- reverts

    function test_Fund_RevertsWhenFundedTwice() public {
        uint256 loanId = _request(1);
        vm.prank(lender);
        book.fund(loanId);

        vm.expectRevert(abi.encodeWithSelector(LoanBook.LoanNotOpen.selector, loanId));
        vm.prank(lender);
        book.fund(loanId);
    }

    function test_Fund_RevertsWhenAnotherLenderFundsAfterwards() public {
        uint256 loanId = _request(1);
        vm.prank(lender);
        book.fund(loanId);

        address other = makeAddr("other");
        token.mintTo(other, P);
        vm.prank(other);
        token.approve(address(book), P);

        vm.expectRevert(abi.encodeWithSelector(LoanBook.LoanNotOpen.selector, loanId));
        vm.prank(other);
        book.fund(loanId);
    }

    function test_Fund_RevertsOnSelfFunding() public {
        uint256 loanId = _request(1);
        vm.expectRevert(LoanBook.SelfFunding.selector);
        vm.prank(borrower);
        book.fund(loanId);
    }

    function test_Fund_RevertsOnUnknownId() public {
        vm.expectRevert(abi.encodeWithSelector(LoanBook.LoanNotFound.selector, 7));
        vm.prank(lender);
        book.fund(7);
    }

    function test_Fund_RevertsOnIdZero() public {
        vm.expectRevert(abi.encodeWithSelector(LoanBook.LoanNotFound.selector, 0));
        vm.prank(lender);
        book.fund(0);
    }

    function test_Fund_RevertsWithoutAllowance() public {
        uint256 loanId = _request(1);
        address noApproval = makeAddr("noApproval");
        token.mintTo(noApproval, P);

        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(book), 0, P
            )
        );
        vm.prank(noApproval);
        book.fund(loanId);

        assertEq(uint8(book.getLoan(loanId).status), uint8(LoanBook.Status.Open));
    }

    function test_Fund_RevertsWithTooLittleBalance() public {
        uint256 loanId = _request(1);
        address poor = makeAddr("poor");
        token.mintTo(poor, P - 1);
        vm.prank(poor);
        token.approve(address(book), P);

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, poor, P - 1, P)
        );
        vm.prank(poor);
        book.fund(loanId);

        assertEq(uint8(book.getLoan(loanId).status), uint8(LoanBook.Status.Open));
    }

    // ------------------------------------------------------- locked terms

    function test_Fund_KeepsTheRequestedTermsUntouched() public {
        uint256 first = _request(3);
        vm.prank(borrower);
        uint256 second = book.requestLoan(50e6, 2500, 30, 2);

        vm.prank(lender);
        book.fund(first);

        LoanBook.Loan memory a = book.getLoan(first);
        assertEq(a.borrower, borrower);
        assertEq(a.interestRateBps, 1000);
        assertEq(a.termDays, 90);
        assertEq(a.installments, 3);
        assertEq(a.principal, P);

        // Funding the second loan and making a third request leaves the first one alone.
        vm.prank(lender);
        book.fund(second);
        vm.prank(borrower);
        book.requestLoan(1e6, 100, 1, 1);

        LoanBook.Loan memory b = book.getLoan(first);
        assertEq(b.borrower, a.borrower);
        assertEq(b.interestRateBps, a.interestRateBps);
        assertEq(b.termDays, a.termDays);
        assertEq(b.installments, a.installments);
        assertEq(b.principal, a.principal);
        assertEq(b.lender, a.lender);
        assertEq(b.fundedAt, a.fundedAt);
        assertEq(b.totalDue, a.totalDue);

        LoanBook.Loan memory c = book.getLoan(second);
        assertEq(c.interestRateBps, 2500);
        assertEq(c.termDays, 30);
        assertEq(c.installments, 2);
        assertEq(c.principal, 50e6);
    }

    // ------------------------------------------------------------- time

    function test_Fund_UsesTheBlockTimestampAsFundedAt() public {
        uint256 loanId = _request(1);
        vm.warp(1_900_000_123);
        vm.prank(lender);
        book.fund(loanId);
        assertEq(book.getLoan(loanId).fundedAt, 1_900_000_123);
    }

    function test_Fund_DueDateIsFundedAtPlusTermDays() public {
        vm.prank(borrower);
        uint256 loanId = book.requestLoan(P, 1000, 365, 6);
        vm.warp(1_700_000_000);

        vm.expectEmit(true, true, true, true, address(book));
        emit LoanFunded(loanId, lender, borrower, P, 1_700_000_000, 1_700_000_000 + 365 days);

        vm.prank(lender);
        book.fund(loanId);
    }

    function test_DueDateOf_AddsWholeDays() public view {
        assertEq(book.dueDateOf(1000, 1), 1000 + 1 days);
        assertEq(book.dueDateOf(1000, 365), 1000 + 365 days);
    }

    // ------------------------------------------------------------ lenders

    function test_Fund_OneLenderCanFundTwoRequests() public {
        uint256 first = _request(1);
        uint256 second = _request(2);

        vm.startPrank(lender);
        book.fund(first);
        book.fund(second);
        vm.stopPrank();

        assertEq(book.getLoan(first).lender, lender);
        assertEq(book.getLoan(second).lender, lender);
        assertEq(token.balanceOf(address(book)), 0);
        assertEq(token.balanceOf(lender), 5_000e6 - 2 * P);
    }

    function test_Fund_BookNeverHoldsTokens() public {
        uint256 loanId = _request(2);
        vm.prank(lender);
        book.fund(loanId);
        assertEq(token.balanceOf(address(book)), 0);
    }

    function test_Fund_MaxPrincipalTotalDueFitsTheStoredField() public view {
        uint256 max = book.MAX_PRINCIPAL();
        uint256 total = book.totalDueFor(max, 5000, 365);
        assertLe(total, type(uint128).max);
        assertLe(total, max + max / 2);
    }

    function test_Getters_UnknownIdReverts() public {
        vm.expectRevert(abi.encodeWithSelector(LoanBook.LoanNotFound.selector, 99));
        book.getLoan(99);
    }
}
