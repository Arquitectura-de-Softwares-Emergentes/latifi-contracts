// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LoanBook} from "../src/LoanBook.sol";
import {LoanBookBase} from "./utils/LoanBookBase.sol";

contract LoanBookRequestTest is LoanBookBase {
    // ---------------------------------------------------------------- tracer

    function test_RequestLoan_StoresOpenLoanAndEmitsEvent() public {
        vm.expectEmit(true, true, false, true, address(book));
        emit LoanRequested(1, borrower, P, 1000, 90, 3);

        vm.prank(borrower);
        uint256 loanId = book.requestLoan(P, 1000, 90, 3);

        assertEq(loanId, 1);
        assertEq(book.loanCount(), 1);

        LoanBook.Loan memory loan = book.getLoan(1);
        assertEq(loan.borrower, borrower);
        assertEq(loan.interestRateBps, 1000);
        assertEq(loan.termDays, 90);
        assertEq(loan.installments, 3);
        assertEq(uint8(loan.status), uint8(LoanBook.Status.Open));
        assertEq(loan.lender, address(0));
        assertEq(loan.fundedAt, 0);
        assertEq(loan.principal, P);
        assertEq(loan.totalDue, 0);
        assertEq(loan.totalPaid, 0);
    }

    // ---------------------------------------------------------------- amount

    function test_RequestLoan_RevertsOnZeroAmount() public {
        vm.expectRevert(LoanBook.ZeroAmount.selector);
        vm.prank(borrower);
        book.requestLoan(0, 1000, 90, 3);
    }

    function test_RequestLoan_RevertsOnUint256MaxAmount() public {
        uint256 max = book.MAX_PRINCIPAL();
        vm.expectRevert(
            abi.encodeWithSelector(LoanBook.AmountTooLarge.selector, type(uint256).max, max)
        );
        vm.prank(borrower);
        book.requestLoan(type(uint256).max, 1000, 90, 3);
    }

    function test_RequestLoan_RevertsOnAmountAboveMaxPrincipal() public {
        uint256 max = book.MAX_PRINCIPAL();
        vm.expectRevert(abi.encodeWithSelector(LoanBook.AmountTooLarge.selector, max + 1, max));
        vm.prank(borrower);
        book.requestLoan(max + 1, 1000, 90, 3);
    }

    function test_RequestLoan_AcceptsMaxPrincipal() public {
        uint256 max = book.MAX_PRINCIPAL();
        vm.prank(borrower);
        uint256 loanId = book.requestLoan(max, 1000, 90, 3);
        assertEq(book.getLoan(loanId).principal, max);
    }

    function test_RequestLoan_AcceptsSmallestAmount() public {
        vm.prank(borrower);
        uint256 loanId = book.requestLoan(1, 1000, 90, 3);
        assertEq(book.getLoan(loanId).principal, 1);
    }

    // ------------------------------------------------------------------ rate

    function test_RequestLoan_RevertsOnZeroRate() public {
        vm.expectRevert(abi.encodeWithSelector(LoanBook.RateOutOfRange.selector, 0));
        vm.prank(borrower);
        book.requestLoan(P, 0, 90, 3);
    }

    function test_RequestLoan_RevertsOnRateAboveMax() public {
        vm.expectRevert(abi.encodeWithSelector(LoanBook.RateOutOfRange.selector, 5001));
        vm.prank(borrower);
        book.requestLoan(P, 5001, 90, 3);
    }

    function test_RequestLoan_RevertsOnUint16MaxRate() public {
        vm.expectRevert(
            abi.encodeWithSelector(LoanBook.RateOutOfRange.selector, uint256(type(uint16).max))
        );
        vm.prank(borrower);
        book.requestLoan(P, type(uint16).max, 90, 3);
    }

    function test_RequestLoan_AcceptsRateBounds() public {
        vm.startPrank(borrower);
        uint256 low = book.requestLoan(P, 1, 90, 3);
        uint256 high = book.requestLoan(P, 5000, 90, 3);
        vm.stopPrank();
        assertEq(book.getLoan(low).interestRateBps, 1);
        assertEq(book.getLoan(high).interestRateBps, 5000);
    }

    // ------------------------------------------------------------------ term

    function test_RequestLoan_RevertsOnZeroTerm() public {
        vm.expectRevert(abi.encodeWithSelector(LoanBook.TermOutOfRange.selector, 0));
        vm.prank(borrower);
        book.requestLoan(P, 1000, 0, 3);
    }

    function test_RequestLoan_RevertsOnTermAboveMax() public {
        vm.expectRevert(abi.encodeWithSelector(LoanBook.TermOutOfRange.selector, 366));
        vm.prank(borrower);
        book.requestLoan(P, 1000, 366, 3);
    }

    function test_RequestLoan_RevertsOnUint32MaxTerm() public {
        vm.expectRevert(
            abi.encodeWithSelector(LoanBook.TermOutOfRange.selector, uint256(type(uint32).max))
        );
        vm.prank(borrower);
        book.requestLoan(P, 1000, type(uint32).max, 3);
    }

    function test_RequestLoan_AcceptsTermBounds() public {
        vm.startPrank(borrower);
        uint256 low = book.requestLoan(P, 1000, 1, 3);
        uint256 high = book.requestLoan(P, 1000, 365, 3);
        vm.stopPrank();
        assertEq(book.getLoan(low).termDays, 1);
        assertEq(book.getLoan(high).termDays, 365);
    }

    // ---------------------------------------------------------- installments

    function test_RequestLoan_RevertsOnZeroInstallments() public {
        vm.expectRevert(abi.encodeWithSelector(LoanBook.InstallmentsOutOfRange.selector, 0));
        vm.prank(borrower);
        book.requestLoan(P, 1000, 90, 0);
    }

    function test_RequestLoan_RevertsOnInstallmentsAboveMax() public {
        vm.expectRevert(abi.encodeWithSelector(LoanBook.InstallmentsOutOfRange.selector, 7));
        vm.prank(borrower);
        book.requestLoan(P, 1000, 90, 7);
    }

    function test_RequestLoan_RevertsOnUint8MaxInstallments() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                LoanBook.InstallmentsOutOfRange.selector, uint256(type(uint8).max)
            )
        );
        vm.prank(borrower);
        book.requestLoan(P, 1000, 90, type(uint8).max);
    }

    function test_RequestLoan_AcceptsInstallmentBounds() public {
        vm.startPrank(borrower);
        uint256 low = book.requestLoan(P, 1000, 90, 1);
        uint256 high = book.requestLoan(P, 1000, 90, 6);
        vm.stopPrank();
        assertEq(book.getLoan(low).installments, 1);
        assertEq(book.getLoan(high).installments, 6);
    }

    // ----------------------------------------------------------- check order

    function test_RequestLoan_ChecksAmountBeforeRate() public {
        vm.expectRevert(LoanBook.ZeroAmount.selector);
        vm.prank(borrower);
        book.requestLoan(0, 0, 0, 0);
    }

    function test_RequestLoan_ChecksRateBeforeTerm() public {
        vm.expectRevert(abi.encodeWithSelector(LoanBook.RateOutOfRange.selector, 0));
        vm.prank(borrower);
        book.requestLoan(P, 0, 0, 0);
    }

    function test_RequestLoan_ChecksTermBeforeInstallments() public {
        vm.expectRevert(abi.encodeWithSelector(LoanBook.TermOutOfRange.selector, 0));
        vm.prank(borrower);
        book.requestLoan(P, 1000, 0, 0);
    }

    // ----------------------------------------------------------------- state

    function test_RequestLoan_AssignsSequentialIdsAndKeepsOwnTerms() public {
        address other = makeAddr("other");

        vm.prank(borrower);
        uint256 first = book.requestLoan(P, 1000, 90, 3);
        vm.prank(other);
        uint256 second = book.requestLoan(2 * P, 2500, 30, 1);

        assertEq(first, 1);
        assertEq(second, 2);
        assertEq(book.loanCount(), 2);

        LoanBook.Loan memory a = book.getLoan(1);
        LoanBook.Loan memory b = book.getLoan(2);
        assertEq(a.borrower, borrower);
        assertEq(a.principal, P);
        assertEq(a.interestRateBps, 1000);
        assertEq(a.termDays, 90);
        assertEq(a.installments, 3);
        assertEq(b.borrower, other);
        assertEq(b.principal, 2 * P);
        assertEq(b.interestRateBps, 2500);
        assertEq(b.termDays, 30);
        assertEq(b.installments, 1);
    }

    function test_RequestLoan_DoesNotMoveFunds() public {
        uint256 borrowerBefore = token.balanceOf(borrower);
        uint256 lenderBefore = token.balanceOf(lender);

        _request(3);

        assertEq(token.balanceOf(borrower), borrowerBefore);
        assertEq(token.balanceOf(lender), lenderBefore);
        assertEq(token.balanceOf(address(book)), 0);
    }

    function test_RequestLoan_FailedRequestDoesNotConsumeAnId() public {
        vm.prank(borrower);
        vm.expectRevert(LoanBook.ZeroAmount.selector);
        book.requestLoan(0, 1000, 90, 3);

        assertEq(book.loanCount(), 0);
        assertEq(_request(1), 1);
    }

    // ----------------------------------------------------------------- views

    function test_GetLoan_RevertsForIdZero() public {
        vm.expectRevert(abi.encodeWithSelector(LoanBook.LoanNotFound.selector, 0));
        book.getLoan(0);
    }

    function test_GetLoan_RevertsForUnknownId() public {
        _request(3);
        vm.expectRevert(abi.encodeWithSelector(LoanBook.LoanNotFound.selector, 99));
        book.getLoan(99);
    }

    function test_ReputationOf_IsZeroForFreshWallet() public view {
        LoanBook.Reputation memory rep = book.reputationOf(borrower);
        assertEq(rep.onTime, 0);
        assertEq(rep.late, 0);
        assertEq(rep.defaulted, 0);
    }

    function test_ReputationOf_StaysZeroAfterRequest() public {
        _request(3);
        LoanBook.Reputation memory rep = book.reputationOf(borrower);
        assertEq(rep.onTime + rep.late + rep.defaulted, 0);
    }

    // ----------------------------------------------------------- constructor

    function test_Constructor_RevertsOnZeroToken() public {
        vm.expectRevert(LoanBook.ZeroTokenAddress.selector);
        new LoanBook(IERC20(address(0)));
    }

    function test_Constructor_StoresToken() public view {
        assertEq(address(book.TOKEN()), address(token));
    }

    function test_Constants_MatchTheDocumentedLimits() public view {
        assertEq(book.MAX_RATE_BPS(), 5000);
        assertEq(book.MAX_TERM_DAYS(), 365);
        assertEq(book.MAX_INSTALLMENTS(), 6);
        assertEq(book.MAX_PRINCIPAL(), type(uint128).max / 2);
    }

    // ------------------------------------------------------------------ fuzz

    function testFuzz_RequestLoan_AcceptsEveryInRangeInput(
        uint256 amount,
        uint16 rate,
        uint32 term,
        uint8 installments
    ) public {
        amount = bound(amount, 1, book.MAX_PRINCIPAL());
        rate = uint16(bound(rate, 1, 5000));
        term = uint32(bound(term, 1, 365));
        installments = uint8(bound(installments, 1, 6));

        vm.prank(borrower);
        uint256 loanId = book.requestLoan(amount, rate, term, installments);

        LoanBook.Loan memory loan = book.getLoan(loanId);
        assertEq(loan.principal, amount);
        assertEq(loan.interestRateBps, rate);
        assertEq(loan.termDays, term);
        assertEq(loan.installments, installments);
        assertEq(uint8(loan.status), uint8(LoanBook.Status.Open));
    }
}
