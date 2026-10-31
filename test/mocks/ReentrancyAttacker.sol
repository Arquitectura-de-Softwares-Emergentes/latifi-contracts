// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LoanBook} from "../../src/LoanBook.sol";
import {IHookReceiver, IHookSender} from "./ReentrantToken.sol";

/// @notice Test-only wallet contract that can act as borrower or lender of a LoanBook and re-enters
/// the book once from a token hook. It records what happened so a test can prove that the attack
/// really ran (attempts), what the book answered (lastError) and which status it saw from inside
/// the hook (statusSeen). Never imported by src/.
contract ReentrancyAttacker is IHookSender, IHookReceiver {
    /// @dev Which token hook triggers the re-entry.
    enum Hook {
        None,
        OnReceive,
        OnSend
    }

    LoanBook public immutable BOOK;

    Hook public hook;
    bytes public payload;
    bool public swallow;
    uint256 public watchLoanId;

    uint256 public attempts;
    uint256 public successes;
    bytes public lastError;
    LoanBook.Status public statusSeen;

    bool private _inside;

    constructor(LoanBook book) {
        BOOK = book;
    }

    /// @param which Hook that fires the attack.
    /// @param callData Encoded call to the book that the hook sends.
    /// @param swallowRevert True to catch the revert of the call, false to bubble it up.
    /// @param loanIdToWatch Loan whose status is read just before the call.
    function arm(Hook which, bytes calldata callData, bool swallowRevert, uint256 loanIdToWatch)
        external
    {
        hook = which;
        payload = callData;
        swallow = swallowRevert;
        watchLoanId = loanIdToWatch;
    }

    function request(uint256 amount, uint16 rateBps, uint32 termDays, uint8 installments)
        external
        returns (uint256)
    {
        return BOOK.requestLoan(amount, rateBps, termDays, installments);
    }

    function fund(uint256 loanId) external {
        BOOK.fund(loanId);
    }

    function repay(uint256 loanId, uint256 amount) external {
        BOOK.repay(loanId, amount);
    }

    function markDefaulted(uint256 loanId) external {
        BOOK.markDefaulted(loanId);
    }

    function approveBook(IERC20 token, uint256 amount) external {
        token.approve(address(BOOK), amount);
    }

    function tokensToSend(address, address, uint256) external override {
        if (hook == Hook.OnSend) _reenter();
    }

    function tokensReceived(address, address, uint256) external override {
        if (hook == Hook.OnReceive) _reenter();
    }

    function _reenter() private {
        if (_inside) return;
        _inside = true;
        attempts++;
        // read only probe before the call, to show the book already wrote its state
        statusSeen = BOOK.getLoan(watchLoanId).status;
        (bool ok, bytes memory ret) = address(BOOK).call(payload);
        if (ok) successes++;
        lastError = ret;
        if (!ok && !swallow) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        _inside = false;
    }
}
