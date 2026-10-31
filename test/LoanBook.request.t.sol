// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {LoanBook} from "../src/LoanBook.sol";
import {LoanBookBase} from "./utils/LoanBookBase.sol";

contract LoanBookRequestTest is LoanBookBase {
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
}
