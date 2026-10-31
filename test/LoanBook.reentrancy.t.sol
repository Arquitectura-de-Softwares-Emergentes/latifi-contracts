// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {LoanBook} from "../src/LoanBook.sol";
import {LoanBookBase} from "./utils/LoanBookBase.sol";
import {FeeToken} from "./mocks/FeeToken.sol";
import {ReentrancyAttacker} from "./mocks/ReentrancyAttacker.sol";
import {ReentrantToken} from "./mocks/ReentrantToken.sol";

/// @notice Malicious receiver suite. The token hands control to a hostile wallet in the middle of a
/// transfer and the wallet calls back into the book. For a book that never holds tokens, "drains
/// zero funds" means five things, and every scenario checks them: the book ends with 0 tokens, each
/// party paid or received exactly the legitimate amount once, the attacker gained nothing extra,
/// the loan state is consistent, and the harness really re-entered (attempts is 1, because a
/// mis-armed attacker would give a false pass).
contract LoanBookReentrancyTest is LoanBookBase {
    // Total due of the standard loan: 1000e6 at 1000 bps for 90 days.
    uint256 private constant TOTAL = 1_024_657_534;
    uint256 private constant START = 1_800_000_000;

    ReentrantToken private htoken;
    LoanBook private hbook;

    function setUp() public override {
        super.setUp();
        (htoken, hbook) = _hookedWorld();
        vm.warp(START);
    }

    // ------------------------------------------------------------------ borrower hook on receive

    /// @dev The borrower receives the principal and re-enters fund. The revert bubbles up, so the
    /// whole fund reverts with the guard's own error. A reverted run cannot keep the attempts
    /// counter, so the guard selector itself is the proof that the re-entry happened (it can only
    /// come from a second entry), and expectCall pins that fund was entered twice.
    function test_BorrowerHookReentersFundAndBubbles() public {
        ReentrancyAttacker evil = _attacker();
        uint256 id = evil.request(P, 1000, 90, 1);
        _fundWallet(lender, P);
        evil.arm(ReentrancyAttacker.Hook.OnReceive, abi.encodeCall(LoanBook.fund, (id)), false, id);
        uint256 lenderBefore = htoken.balanceOf(lender);

        vm.expectCall(address(hbook), abi.encodeCall(LoanBook.fund, (id)), 2);
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        vm.prank(lender);
        hbook.fund(id);

        assertEq(htoken.balanceOf(lender), lenderBefore);
        assertEq(htoken.balanceOf(address(evil)), 0);
        assertEq(htoken.balanceOf(address(hbook)), 0);
        assertEq(uint8(hbook.getLoan(id).status), uint8(LoanBook.Status.Open));
        assertEq(hbook.getLoan(id).lender, address(0));
    }

    function test_BorrowerHookReentersFundAndSwallows() public {
        ReentrancyAttacker evil = _attacker();
        uint256 id = evil.request(P, 1000, 90, 1);
        _fundWallet(lender, P);
        evil.arm(ReentrancyAttacker.Hook.OnReceive, abi.encodeCall(LoanBook.fund, (id)), true, id);
        uint256 lenderBefore = htoken.balanceOf(lender);

        vm.prank(lender);
        hbook.fund(id);

        assertEq(evil.attempts(), 1);
        assertEq(evil.successes(), 0);
        assertEq(
            bytes4(evil.lastError()), ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector
        );
        assertEq(uint8(evil.statusSeen()), uint8(LoanBook.Status.Active));
        assertEq(lenderBefore - htoken.balanceOf(lender), P);
        assertEq(htoken.balanceOf(address(evil)), P);
        assertEq(htoken.balanceOf(address(hbook)), 0);
        LoanBook.Loan memory loan = hbook.getLoan(id);
        assertEq(uint8(loan.status), uint8(LoanBook.Status.Active));
        assertEq(loan.lender, lender);
        assertEq(loan.totalDue, TOTAL);
        assertEq(loan.totalPaid, 0);
    }

    /// @dev The borrower receives the principal and tries to repay at once. State is written before
    /// the token call, so the probe sees Active, and without the guard this repay would work.
    function test_BorrowerHookReentersRepayWhileReceivingPrincipal() public {
        ReentrancyAttacker evil = _attacker();
        uint256 id = evil.request(P, 1000, 90, 1);
        evil.approveBook(htoken, type(uint256).max);
        _fundWallet(lender, P);
        evil.arm(
            ReentrancyAttacker.Hook.OnReceive, abi.encodeCall(LoanBook.repay, (id, 1)), true, id
        );
        uint256 lenderBefore = htoken.balanceOf(lender);

        vm.prank(lender);
        hbook.fund(id);

        assertEq(evil.attempts(), 1);
        assertEq(evil.successes(), 0);
        assertEq(
            bytes4(evil.lastError()), ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector
        );
        assertEq(uint8(evil.statusSeen()), uint8(LoanBook.Status.Active));
        assertEq(htoken.balanceOf(address(hbook)), 0);
        assertEq(lenderBefore - htoken.balanceOf(lender), P);
        assertEq(htoken.balanceOf(address(evil)), P);
        assertEq(hbook.getLoan(id).totalPaid, 0);
        assertEq(hbook.reputationOf(address(evil)).onTime, 0);
        assertEq(hbook.reputationOf(address(evil)).late, 0);
    }

    // ------------------------------------------------------------------ lender hooks

    /// @dev The lender hook fires while the lender is sending the principal and tries to fund a
    /// second open request. The second loan must stay open and the lender pays exactly once.
    function test_LenderHookOnSendCannotFundSecondLoan() public {
        ReentrancyAttacker evil = _attacker();
        htoken.mint(address(evil), P);
        evil.approveBook(htoken, type(uint256).max);
        uint256 first = _open(1);
        uint256 second = _open(1);
        evil.arm(
            ReentrancyAttacker.Hook.OnSend, abi.encodeCall(LoanBook.fund, (second)), true, first
        );
        uint256 borrowerBefore = htoken.balanceOf(borrower);

        evil.fund(first);

        assertEq(evil.attempts(), 1);
        assertEq(evil.successes(), 0);
        assertEq(
            bytes4(evil.lastError()), ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector
        );
        assertEq(uint8(evil.statusSeen()), uint8(LoanBook.Status.Active));
        assertEq(htoken.balanceOf(address(hbook)), 0);
        assertEq(htoken.balanceOf(address(evil)), 0);
        assertEq(htoken.balanceOf(borrower) - borrowerBefore, P);
        assertEq(uint8(hbook.getLoan(first).status), uint8(LoanBook.Status.Active));
        assertEq(uint8(hbook.getLoan(second).status), uint8(LoanBook.Status.Open));
        assertEq(hbook.getLoan(second).lender, address(0));
    }

    /// @dev The lender receives a repayment and tries to repay again from its own hook. Without the
    /// guard the inner call would fail on NotBorrower, so asserting the guard selector proves that
    /// the guard, not an access check, stopped the re-entry. This one bubbles the revert.
    function test_LenderHookOnReceiveCannotReenterRepay() public {
        (ReentrancyAttacker evil, uint256 id) = _lenderAttackerWithLoan(1);
        uint256 amount = TOTAL;
        evil.arm(
            ReentrancyAttacker.Hook.OnReceive, abi.encodeCall(LoanBook.repay, (id, 1)), false, id
        );
        uint256 borrowerBefore = htoken.balanceOf(borrower);

        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        vm.prank(borrower);
        hbook.repay(id, amount);

        assertEq(htoken.balanceOf(borrower), borrowerBefore);
        assertEq(htoken.balanceOf(address(evil)), 0);
        assertEq(htoken.balanceOf(address(hbook)), 0);
        assertEq(hbook.getLoan(id).totalPaid, 0);
        assertEq(hbook.reputationOf(borrower).onTime, 0);

        // the same attack with a swallowing wallet lets the one legitimate payment through
        evil.arm(
            ReentrancyAttacker.Hook.OnReceive, abi.encodeCall(LoanBook.repay, (id, 1)), true, id
        );
        vm.prank(borrower);
        hbook.repay(id, amount);

        assertEq(evil.attempts(), 1);
        assertEq(evil.successes(), 0);
        assertEq(
            bytes4(evil.lastError()), ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector
        );
        assertEq(uint8(evil.statusSeen()), uint8(LoanBook.Status.Repaid));
        assertEq(borrowerBefore - htoken.balanceOf(borrower), amount);
        assertEq(htoken.balanceOf(address(evil)), amount);
        assertEq(htoken.balanceOf(address(hbook)), 0);
        assertEq(hbook.getLoan(id).totalPaid, amount);
        assertEq(uint8(hbook.getLoan(id).status), uint8(LoanBook.Status.Repaid));
        assertEq(hbook.reputationOf(borrower).onTime, 1);
    }

    /// @dev A late partial payment keeps the installment overdue beyond the grace period. A missing
    /// guard would let the lender hook mark the loan defaulted in the middle of the payment.
    function test_LenderHookOnReceiveCannotMarkDefaultedDuringLatePayment() public {
        (ReentrancyAttacker evil, uint256 id) = _lenderAttackerWithLoan(1);
        uint256 dueAt = hbook.installmentDueAt(id, 1);
        vm.warp(dueAt + hbook.GRACE_PERIOD() + 1);
        evil.arm(
            ReentrancyAttacker.Hook.OnReceive,
            abi.encodeCall(LoanBook.markDefaulted, (id)),
            true,
            id
        );
        uint256 half = TOTAL / 2;
        uint256 borrowerBefore = htoken.balanceOf(borrower);

        vm.prank(borrower);
        hbook.repay(id, half);

        assertEq(evil.attempts(), 1);
        assertEq(evil.successes(), 0);
        assertEq(
            bytes4(evil.lastError()), ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector
        );
        assertEq(uint8(evil.statusSeen()), uint8(LoanBook.Status.Active));
        assertEq(borrowerBefore - htoken.balanceOf(borrower), half);
        assertEq(htoken.balanceOf(address(evil)), half);
        assertEq(htoken.balanceOf(address(hbook)), 0);
        LoanBook.Loan memory loan = hbook.getLoan(id);
        assertEq(uint8(loan.status), uint8(LoanBook.Status.Active));
        assertEq(loan.totalPaid, half);
        assertEq(hbook.reputationOf(borrower).late, 1);
        assertEq(hbook.reputationOf(borrower).onTime, 0);
        assertEq(hbook.reputationOf(borrower).defaulted, 0);
    }

    /// @dev The borrower is the one sending in a repayment. Its send hook tries to repay again while
    /// the first payment is in flight.
    function test_BorrowerHookOnSendCannotRepayTwice() public {
        ReentrancyAttacker evil = _attacker();
        uint256 id = evil.request(P, 1000, 90, 2);
        _fundWallet(lender, P);
        vm.prank(lender);
        hbook.fund(id);
        htoken.mint(address(evil), TOTAL);
        evil.approveBook(htoken, type(uint256).max);
        uint256 first = TOTAL / 2;
        evil.arm(
            ReentrancyAttacker.Hook.OnSend, abi.encodeCall(LoanBook.repay, (id, first)), true, id
        );
        uint256 evilBefore = htoken.balanceOf(address(evil));
        uint256 lenderBefore = htoken.balanceOf(lender);

        evil.repay(id, first);

        assertEq(evil.attempts(), 1);
        assertEq(evil.successes(), 0);
        assertEq(
            bytes4(evil.lastError()), ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector
        );
        assertEq(uint8(evil.statusSeen()), uint8(LoanBook.Status.Active));
        assertEq(evilBefore - htoken.balanceOf(address(evil)), first);
        assertEq(htoken.balanceOf(lender) - lenderBefore, first);
        assertEq(htoken.balanceOf(address(hbook)), 0);
        assertEq(hbook.getLoan(id).totalPaid, first);
        assertEq(hbook.reputationOf(address(evil)).onTime, 1);
    }

    // ------------------------------------------------------------------ fee on transfer

    function test_FeeTokenMakesFundRevertAndKeepsLoanOpen() public {
        (FeeToken ftoken, LoanBook fbook) = _feeWorld();
        vm.prank(borrower);
        uint256 id = fbook.requestLoan(P, 1000, 90, 1);
        ftoken.setFee(true);
        uint256 lenderBefore = ftoken.balanceOf(lender);
        uint256 borrowerBefore = ftoken.balanceOf(borrower);

        vm.expectRevert(
            abi.encodeWithSelector(LoanBook.UnexpectedTransferAmount.selector, P, P - P / 100)
        );
        vm.prank(lender);
        fbook.fund(id);

        assertEq(ftoken.balanceOf(lender), lenderBefore);
        assertEq(ftoken.balanceOf(borrower), borrowerBefore);
        assertEq(ftoken.balanceOf(address(fbook)), 0);
        LoanBook.Loan memory loan = fbook.getLoan(id);
        assertEq(uint8(loan.status), uint8(LoanBook.Status.Open));
        assertEq(loan.lender, address(0));
        assertEq(loan.totalDue, 0);
    }

    function test_FeeTokenMakesRepayRevertAndKeepsCounters() public {
        (FeeToken ftoken, LoanBook fbook) = _feeWorld();
        vm.prank(borrower);
        uint256 id = fbook.requestLoan(P, 1000, 90, 1);
        vm.prank(lender);
        fbook.fund(id);
        ftoken.setFee(true);
        uint256 lenderBefore = ftoken.balanceOf(lender);
        uint256 borrowerBefore = ftoken.balanceOf(borrower);
        uint256 amount = 500e6;

        vm.expectRevert(
            abi.encodeWithSelector(
                LoanBook.UnexpectedTransferAmount.selector, amount, amount - amount / 100
            )
        );
        vm.prank(borrower);
        fbook.repay(id, amount);

        assertEq(ftoken.balanceOf(lender), lenderBefore);
        assertEq(ftoken.balanceOf(borrower), borrowerBefore);
        assertEq(ftoken.balanceOf(address(fbook)), 0);
        LoanBook.Loan memory loan = fbook.getLoan(id);
        assertEq(uint8(loan.status), uint8(LoanBook.Status.Active));
        assertEq(loan.totalPaid, 0);
        assertEq(fbook.reputationOf(borrower).onTime, 0);
        assertEq(fbook.reputationOf(borrower).late, 0);
    }

    // ------------------------------------------------------------------ documented limitation

    /// @dev A lender wallet whose receive hook reverts blocks repayment. This is the documented
    /// limitation of plugging an arbitrary token or wallet in. The book still holds nothing.
    function test_RevertingLenderHookBlocksRepayment() public {
        (ReentrancyAttacker evil, uint256 id) = _lenderAttackerWithLoan(1);
        evil.arm(
            ReentrancyAttacker.Hook.OnReceive, abi.encodeCall(LoanBook.getLoan, (999)), false, id
        );
        uint256 borrowerBefore = htoken.balanceOf(borrower);

        vm.expectRevert(abi.encodeWithSelector(LoanBook.LoanNotFound.selector, 999));
        vm.prank(borrower);
        hbook.repay(id, TOTAL);

        assertEq(htoken.balanceOf(borrower), borrowerBefore);
        assertEq(htoken.balanceOf(address(evil)), 0);
        assertEq(htoken.balanceOf(address(hbook)), 0);
        assertEq(hbook.getLoan(id).totalPaid, 0);
        assertEq(uint8(hbook.getLoan(id).status), uint8(LoanBook.Status.Active));
    }

    // ------------------------------------------------------------------ helpers

    function _hookedWorld() private returns (ReentrantToken t, LoanBook b) {
        t = new ReentrantToken();
        b = new LoanBook(t);
    }

    function _feeWorld() private returns (FeeToken ftoken, LoanBook fbook) {
        ftoken = new FeeToken();
        fbook = new LoanBook(ftoken);
        ftoken.mint(lender, 5_000e6);
        ftoken.mint(borrower, 1_000e6);
        vm.prank(lender);
        ftoken.approve(address(fbook), type(uint256).max);
        vm.prank(borrower);
        ftoken.approve(address(fbook), type(uint256).max);
    }

    function _attacker() private returns (ReentrancyAttacker) {
        return new ReentrancyAttacker(hbook);
    }

    function _fundWallet(address who, uint256 amount) private {
        htoken.mint(who, amount);
        vm.prank(who);
        htoken.approve(address(hbook), type(uint256).max);
    }

    /// @dev The honest borrower requests the standard loan on the hooked book.
    function _open(uint8 installments) private returns (uint256 loanId) {
        vm.prank(borrower);
        loanId = hbook.requestLoan(P, 1000, 90, installments);
    }

    /// @dev Builds a hostile lender wallet that funded a standard loan of the honest borrower, who
    /// holds enough to repay in full. The hook is left unarmed.
    function _lenderAttackerWithLoan(uint8 installments)
        private
        returns (ReentrancyAttacker evil, uint256 id)
    {
        evil = _attacker();
        htoken.mint(address(evil), P);
        evil.approveBook(htoken, type(uint256).max);
        id = _open(installments);
        evil.fund(id);
        _fundWallet(borrower, TOTAL);
        // the borrower got the principal from the lender, so it holds P plus TOTAL here
        assertEq(htoken.balanceOf(address(evil)), 0);
    }
}
