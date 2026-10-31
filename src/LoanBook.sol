// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {ILoanEvents} from "./interfaces/ILoanEvents.sol";

/// @title LoanBook
/// @notice Holds the only copy of every LatiFi loan and never holds tokens. Borrowers publish
/// requests here, and the lending token moves wallet to wallet in later steps of the lifecycle.
/// @dev Immutable, no owner and no admin function. Every state-changing function is guarded by
/// ReentrancyGuardTransient, which needs the transient storage opcodes (cancun). Nothing in this
/// contract takes or stores a price, an exchange rate or an oracle value.
contract LoanBook is ILoanEvents, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @notice Life cycle of a loan. The numeric values are frozen because clients decode them.
    enum Status {
        None,
        Open,
        Active,
        Repaid,
        Defaulted
    }

    /// @notice Everything stored about one loan, packed in four storage slots.
    /// @param borrower Wallet that asked for the loan.
    /// @param interestRateBps Annual simple interest rate in basis points.
    /// @param termDays Length of the loan in days.
    /// @param installments Number of equal installments.
    /// @param status Current life cycle state.
    /// @param lender Wallet that funded the loan, zero while the request is open.
    /// @param fundedAt Unix seconds of the funding, zero while the request is open.
    /// @param principal Requested amount in token base units.
    /// @param totalDue Principal plus interest, fixed at funding, zero while the request is open.
    /// @param totalPaid Sum of the payments received so far.
    struct Loan {
        address borrower;
        uint16 interestRateBps;
        uint32 termDays;
        uint8 installments;
        Status status;
        address lender;
        uint64 fundedAt;
        uint128 principal;
        uint128 totalDue;
        uint128 totalPaid;
    }

    /// @notice Per borrower counters. Only the contract logic changes them.
    /// @param onTime Payments that arrived on or before their due date.
    /// @param late Payments that arrived after their due date.
    /// @param defaulted Loans marked as defaulted.
    struct Reputation {
        uint32 onTime;
        uint32 late;
        uint32 defaulted;
    }

    /// @notice Highest accepted annual rate, 5000 bps is 50 percent.
    uint256 public constant MAX_RATE_BPS = 5000;
    /// @notice Longest accepted term in days.
    uint256 public constant MAX_TERM_DAYS = 365;
    /// @notice Highest accepted number of installments.
    uint256 public constant MAX_INSTALLMENTS = 6;
    /// @notice Highest accepted principal. Half of the uint128 range, so that the principal plus
    /// the largest possible interest still fits in a uint128.
    uint256 public constant MAX_PRINCIPAL = type(uint128).max / 2;

    /// @dev 365 days times 10000 basis points. One floor division by this value equals the chained
    /// divisions by 365 and by 10000.
    uint256 private constant INTEREST_DIVISOR = 365 * 10_000;

    /// @notice Token used for every loan of this book.
    IERC20 public immutable TOKEN;
    /// @notice Number of requests made so far, and the id of the latest one.
    uint256 public loanCount;

    mapping(uint256 loanId => Loan) private _loans;
    mapping(address borrower => Reputation) private _reputation;

    /// @notice The token address given to the constructor is the zero address.
    error ZeroTokenAddress();
    /// @notice The amount is zero.
    error ZeroAmount();
    /// @notice The amount is above the highest accepted principal.
    error AmountTooLarge(uint256 amount, uint256 max);
    /// @notice The rate is zero or above the highest accepted rate.
    error RateOutOfRange(uint256 rateBps);
    /// @notice The term is zero or above the longest accepted term.
    error TermOutOfRange(uint256 termDays);
    /// @notice The number of installments is zero or above the highest accepted number.
    error InstallmentsOutOfRange(uint256 installments);
    /// @notice No loan exists with this id.
    error LoanNotFound(uint256 loanId);
    /// @notice The loan is not an open request, so it cannot be funded.
    error LoanNotOpen(uint256 loanId);
    /// @notice A borrower cannot fund their own request.
    error SelfFunding();
    /// @notice The receiver got a different amount than the one sent, for example a fee on transfer.
    error UnexpectedTransferAmount(uint256 expected, uint256 received);

    /// @param token ERC-20 used as the lending token of this book.
    constructor(IERC20 token) {
        if (address(token) == address(0)) revert ZeroTokenAddress();
        TOKEN = token;
    }

    /// @notice Publishes a loan request. No funds move.
    /// @param amount Requested principal in token base units, from 1 to MAX_PRINCIPAL.
    /// @param interestRateBps Annual simple interest in basis points, from 1 to 5000.
    /// @param termDays Length of the loan in days, from 1 to 365.
    /// @param installments Number of equal installments, from 1 to 6.
    /// @return loanId Identifier of the new request, starting at 1.
    function requestLoan(
        uint256 amount,
        uint16 interestRateBps,
        uint32 termDays,
        uint8 installments
    ) external nonReentrant returns (uint256 loanId) {
        if (amount == 0) revert ZeroAmount();
        if (amount > MAX_PRINCIPAL) revert AmountTooLarge(amount, MAX_PRINCIPAL);
        if (interestRateBps == 0 || interestRateBps > MAX_RATE_BPS) {
            revert RateOutOfRange(interestRateBps);
        }
        if (termDays == 0 || termDays > MAX_TERM_DAYS) revert TermOutOfRange(termDays);
        if (installments == 0 || installments > MAX_INSTALLMENTS) {
            revert InstallmentsOutOfRange(installments);
        }

        loanId = ++loanCount;
        Loan storage loan = _loans[loanId];
        loan.borrower = msg.sender;
        loan.interestRateBps = interestRateBps;
        loan.termDays = termDays;
        loan.installments = installments;
        loan.status = Status.Open;
        // casting to 'uint128' is safe because amount <= MAX_PRINCIPAL = type(uint128).max / 2
        // forge-lint: disable-next-line(unsafe-typecast)
        loan.principal = uint128(amount);

        emit LoanRequested(loanId, msg.sender, amount, interestRateBps, termDays, installments);
    }

    /// @notice Funds an open request. The principal moves from the caller to the borrower in this
    /// transaction, the terms are locked and the total due is fixed.
    /// @dev The caller must have approved this contract for at least the principal. State is written
    /// before the token call.
    /// @param loanId Identifier of the request to fund.
    function fund(uint256 loanId) external nonReentrant {
        Loan storage loan = _existing(loanId);
        if (loan.status != Status.Open) revert LoanNotOpen(loanId);
        address borrower = loan.borrower;
        if (msg.sender == borrower) revert SelfFunding();

        uint256 principal = loan.principal;
        uint32 termDays = loan.termDays;
        // casting to 'uint64' is safe because a block timestamp stays far below 2^64 seconds
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 fundedAt = uint64(block.timestamp);
        // casting to 'uint128' is safe because principal <= MAX_PRINCIPAL = type(uint128).max / 2
        // and the interest is at most half of the principal, so the total is at most 0.75 of the
        // uint128 maximum
        // forge-lint: disable-next-line(unsafe-typecast)
        loan.totalDue = uint128(totalDueFor(principal, loan.interestRateBps, termDays));
        loan.lender = msg.sender;
        loan.fundedAt = fundedAt;
        loan.status = Status.Active;

        _pull(msg.sender, borrower, principal);

        emit LoanFunded(
            loanId, msg.sender, borrower, principal, fundedAt, dueDateOf(fundedAt, termDays)
        );
    }

    /// @notice Total owed for a loan: the principal plus simple annual interest, rounded down.
    /// @param principal Loan amount in token base units.
    /// @param rateBps Annual rate in basis points.
    /// @param termDays Length of the loan in days.
    /// @return The principal plus floor(principal * rateBps * termDays / 3650000).
    function totalDueFor(uint256 principal, uint256 rateBps, uint256 termDays)
        public
        pure
        returns (uint256)
    {
        return principal + (principal * rateBps * termDays) / INTEREST_DIVISOR;
    }

    /// @notice Due date of the final installment.
    /// @param fundedAt Unix seconds of the funding.
    /// @param termDays Length of the loan in days.
    /// @return Unix seconds of fundedAt plus termDays days.
    function dueDateOf(uint64 fundedAt, uint32 termDays) public pure returns (uint64) {
        return fundedAt + uint64(termDays) * 1 days;
    }

    /// @notice Returns the stored data of a loan.
    /// @param loanId Identifier of the loan.
    /// @return The loan, reverts with LoanNotFound for an unknown id.
    function getLoan(uint256 loanId) external view returns (Loan memory) {
        return _existing(loanId);
    }

    /// @notice Returns the counters of a borrower, all zero for a wallet without history.
    /// @param borrower Wallet to read.
    /// @return The on time, late and defaulted counters.
    function reputationOf(address borrower) external view returns (Reputation memory) {
        return _reputation[borrower];
    }

    function _existing(uint256 loanId) private view returns (Loan storage loan) {
        loan = _loans[loanId];
        if (loan.status == Status.None) revert LoanNotFound(loanId);
    }

    /// @dev Moves tokens from one wallet to another and checks that the receiver got the full
    /// amount, which rejects tokens that take a fee on transfer.
    function _pull(address from, address to, uint256 amount) private {
        uint256 balanceBefore = TOKEN.balanceOf(to);
        TOKEN.safeTransferFrom(from, to, amount);
        uint256 received = TOKEN.balanceOf(to) - balanceBefore;
        if (received != amount) revert UnexpectedTransferAmount(amount, received);
    }
}
