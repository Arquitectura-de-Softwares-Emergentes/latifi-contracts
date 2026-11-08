// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {ILoanEvents} from "../../src/interfaces/ILoanEvents.sol";
import {LoanBook} from "../../src/LoanBook.sol";
import {MockStablecoin} from "../../src/MockStablecoin.sol";

/// @notice Shared setup for the LoanBook tests. It inherits ILoanEvents so that child tests can
/// emit the events they expect.
abstract contract LoanBookBase is Test, ILoanEvents {
    uint256 internal constant P = 1_000e6;

    MockStablecoin internal token;
    LoanBook internal book;
    address internal borrower = makeAddr("borrower");
    address internal lender = makeAddr("lender");

    function setUp() public virtual {
        token = new MockStablecoin(address(this));
        book = new LoanBook(token);

        token.mintTo(lender, 5_000e6);
        token.mintTo(borrower, 1_000e6);

        vm.prank(lender);
        token.approve(address(book), type(uint256).max);
        vm.prank(borrower);
        token.approve(address(book), type(uint256).max);
    }

    /// @dev Requests P at 1000 bps for 90 days as the borrower.
    function _request(uint8 installments) internal returns (uint256 loanId) {
        vm.prank(borrower);
        loanId = book.requestLoan(P, 1000, 90, installments);
    }
}
