// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {LoanBook} from "../src/LoanBook.sol";
import {MockStablecoin} from "../src/MockStablecoin.sol";

/// @notice Bounded actor for the invariant run. Three wallets request, fund, repay and mark loans
/// in any order while time moves. Every book call sits in try/catch because most random calls are
/// expected to revert, and the ghost counters only move when a call really succeeded.
contract LoanBookHandler is Test {
    uint256 internal constant ACTOR_BALANCE = 1_000_000e6;

    LoanBook public immutable BOOK;
    address[3] public actors;

    uint256 public ghostRequests;
    uint256 public ghostOnTime;
    uint256 public ghostLate;
    uint256 public ghostDefaults;

    constructor(LoanBook book, MockStablecoin token) {
        BOOK = book;
        for (uint256 i; i < actors.length; ++i) {
            address actor = makeAddr(string.concat("actor", vm.toString(i)));
            actors[i] = actor;
            deal(address(token), actor, ACTOR_BALANCE);
            vm.prank(actor);
            token.approve(address(book), type(uint256).max);
        }
    }

    function request(uint256 actorSeed, uint256 amount, uint256 rate, uint256 term, uint256 n)
        external
    {
        amount = bound(amount, 1, 100_000e6);
        rate = bound(rate, 1, 5000);
        term = bound(term, 1, 365);
        n = bound(n, 1, 6);
        vm.prank(_actor(actorSeed));
        // casts are safe because every input was bounded to the type just above
        // forge-lint: disable-next-line(unsafe-typecast)
        try BOOK.requestLoan(amount, uint16(rate), uint32(term), uint8(n)) {
            ++ghostRequests;
        } catch {}
    }

    function fund(uint256 actorSeed, uint256 loanSeed) external {
        uint256 id = _loanId(loanSeed);
        if (id == 0) return;
        vm.prank(_actor(actorSeed));
        try BOOK.fund(id) {} catch {}
    }

    /// @dev The caller is the borrower unless strangerSeed is a multiple of four. Half of the
    /// payments are a full installment, the rest are a random part of it.
    function repay(uint256 loanSeed, uint256 amountSeed, uint256 strangerSeed) external {
        uint256 id = _loanId(loanSeed);
        if (id == 0) return;
        address caller = strangerSeed % 4 == 0 ? _actor(strangerSeed) : BOOK.getLoan(id).borrower;
        try BOOK.nextInstallment(id) returns (uint256, uint256 dueAt, uint256 due) {
            uint256 amount = amountSeed % 2 == 0 ? due : bound(amountSeed, 1, due);
            // the same comparison the book makes, taken from the handler's own view of time
            bool onTime = block.timestamp <= dueAt;
            vm.prank(caller);
            try BOOK.repay(id, amount) {
                if (onTime) {
                    ++ghostOnTime;
                } else {
                    ++ghostLate;
                }
            } catch {}
        } catch {}
    }

    function markDefaulted(uint256 loanSeed) external {
        uint256 id = _loanId(loanSeed);
        if (id == 0) return;
        try BOOK.markDefaulted(id) {
            ++ghostDefaults;
        } catch {}
    }

    function warp(uint256 secondsForward) external {
        vm.warp(block.timestamp + bound(secondsForward, 1, 30 days));
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[seed % actors.length];
    }

    /// @dev Maps a seed to an existing loan id, or zero while no loan exists.
    function _loanId(uint256 seed) private view returns (uint256) {
        uint256 count = BOOK.loanCount();
        if (count == 0) return 0;
        return bound(seed, 1, count);
    }
}

contract LoanBookInvariantTest is StdInvariant, Test {
    uint256 private constant TOTAL_SUPPLY = 3 * 1_000_000e6;

    MockStablecoin private token;
    LoanBook private book;
    LoanBookHandler private handler;

    function setUp() public {
        vm.warp(1_800_000_000);
        token = new MockStablecoin(address(this));
        book = new LoanBook(token);
        handler = new LoanBookHandler(book, token);

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = LoanBookHandler.request.selector;
        selectors[1] = LoanBookHandler.fund.selector;
        selectors[2] = LoanBookHandler.repay.selector;
        selectors[3] = LoanBookHandler.markDefaulted.selector;
        selectors[4] = LoanBookHandler.warp.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    // ------------------------------------------------------------------ no custody

    function invariant_BookHoldsNoTokens() public view {
        assertEq(token.balanceOf(address(book)), 0);
    }

    function invariant_TokensAreConserved() public view {
        uint256 sum = token.balanceOf(address(book));
        for (uint256 i; i < handler.actorCount(); ++i) {
            sum += token.balanceOf(handler.actors(i));
        }
        assertEq(sum, TOTAL_SUPPLY);
    }

    // ------------------------------------------------------------------ loan accounting

    function invariant_PaidNeverAboveDue() public view {
        uint256 count = book.loanCount();
        for (uint256 id = 1; id <= count; ++id) {
            LoanBook.Loan memory loan = book.getLoan(id);
            assertLe(loan.totalPaid, loan.totalDue);
        }
    }

    function invariant_StatusImpliesAmounts() public view {
        uint256 count = book.loanCount();
        for (uint256 id = 1; id <= count; ++id) {
            LoanBook.Loan memory loan = book.getLoan(id);
            if (loan.status == LoanBook.Status.Repaid) {
                assertEq(loan.totalPaid, loan.totalDue);
                assertGt(loan.totalDue, 0);
            } else if (loan.status == LoanBook.Status.Open) {
                assertEq(loan.totalPaid, 0);
                assertEq(loan.totalDue, 0);
                assertEq(loan.lender, address(0));
            } else if (loan.status == LoanBook.Status.Defaulted) {
                assertLt(loan.totalPaid, loan.totalDue);
                assertTrue(loan.lender != address(0));
            } else if (loan.status == LoanBook.Status.Active) {
                assertLt(loan.totalPaid, loan.totalDue);
                assertTrue(loan.lender != address(0));
            } else {
                // None cannot show up for an id that was handed out
                assertTrue(false);
            }
        }
    }

    // ------------------------------------------------------------------ counters

    function invariant_LoanCountEqualsRequests() public view {
        assertEq(book.loanCount(), handler.ghostRequests());
    }

    function invariant_ReputationCountersEqualSuccessfulCalls() public view {
        uint256 payments;
        uint256 defaults;
        for (uint256 i; i < handler.actorCount(); ++i) {
            LoanBook.Reputation memory rep = book.reputationOf(handler.actors(i));
            payments += uint256(rep.onTime) + uint256(rep.late);
            defaults += rep.defaulted;
        }
        assertEq(payments, handler.ghostOnTime() + handler.ghostLate());
        assertEq(defaults, handler.ghostDefaults());
        // the split by onTime is checked too, not only the sum
        uint256 onTime;
        for (uint256 i; i < handler.actorCount(); ++i) {
            onTime += book.reputationOf(handler.actors(i)).onTime;
        }
        assertEq(onTime, handler.ghostOnTime());
    }

    // ------------------------------------------------------------------ non vacuity

    /// @dev Drives the same handler through a full life of one loan, so the suite cannot pass by
    /// never reaching the interesting states. Seed 1 picks the second actor as lender, and a
    /// stranger seed that is not a multiple of four makes the borrower pay.
    function test_HandlerReachesRepaid() public {
        handler.request(0, 1000e6, 1000, 90, 2);
        handler.fund(1, 1);
        assertEq(uint8(book.getLoan(1).status), uint8(LoanBook.Status.Active));

        handler.repay(1, 0, 1);
        assertEq(uint8(book.getLoan(1).status), uint8(LoanBook.Status.Active));
        handler.repay(1, 0, 1);

        LoanBook.Loan memory loan = book.getLoan(1);
        assertEq(uint8(loan.status), uint8(LoanBook.Status.Repaid));
        assertEq(loan.totalPaid, loan.totalDue);
        assertEq(handler.ghostOnTime(), 2);
        _checkAll();
    }

    function test_HandlerReachesDefaulted() public {
        handler.request(0, 1000e6, 1000, 90, 1);
        handler.fund(1, 1);
        // one more warp than needed: 4 times 30 days is past the due date plus the grace period
        for (uint256 i; i < 4; ++i) {
            handler.warp(30 days);
        }
        handler.markDefaulted(1);

        assertEq(uint8(book.getLoan(1).status), uint8(LoanBook.Status.Defaulted));
        assertEq(handler.ghostDefaults(), 1);
        _checkAll();
    }

    function test_HandlerCountsLatePayment() public {
        handler.request(0, 1000e6, 1000, 90, 1);
        handler.fund(1, 1);
        handler.warp(30 days);
        handler.warp(30 days);
        handler.warp(30 days);
        handler.warp(1 days);
        handler.repay(1, 1, 1);

        assertEq(handler.ghostLate(), 1);
        assertEq(handler.ghostOnTime(), 0);
        _checkAll();
    }

    function _checkAll() private view {
        invariant_BookHoldsNoTokens();
        invariant_TokensAreConserved();
        invariant_PaidNeverAboveDue();
        invariant_StatusImpliesAmounts();
        invariant_LoanCountEqualsRequests();
        invariant_ReputationCountersEqualSuccessfulCalls();
    }
}
