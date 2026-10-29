// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

/// @title ILoanEvents
/// @notice Version 0 of the LatiFi loan lifecycle events. The API indexer, the Android app and the
/// reputation logic all read these events, so the interface lives apart from any implementation.
/// @dev Amounts use the base units of the test stablecoin (6 decimals). Timestamps are Unix
/// seconds. No event carries a price, exchange rate or oracle value: the local-currency display
/// is computed off-chain. See docs/EVENTS.md for units, emit conditions and consumers.
interface ILoanEvents {
    /// @notice Emitted when a borrower's loan request is stored on-chain.
    /// @param loanId Identifier assigned to the request.
    /// @param borrower Address of the requesting wallet.
    /// @param amount Requested principal in stablecoin base units.
    /// @param interestRateBps Flat interest over the whole term, in basis points of the principal.
    /// @param termDays Length of the loan in days, counted from the funding time.
    /// @param installments Number of equal installments, from 1 to 6.
    event LoanRequested(
        uint256 indexed loanId,
        address indexed borrower,
        uint256 amount,
        uint16 interestRateBps,
        uint32 termDays,
        uint8 installments
    );

    /// @notice Emitted when a lender funds a request, the principal moves to the borrower and the
    /// terms are locked.
    /// @param loanId Identifier of the funded loan.
    /// @param lender Address that provided the funds.
    /// @param borrower Address that received the funds.
    /// @param amount Principal transferred, in stablecoin base units.
    /// @param fundedAt Unix seconds when the funds moved.
    /// @param dueDate Unix seconds of the final installment.
    event LoanFunded(
        uint256 indexed loanId,
        address indexed lender,
        address indexed borrower,
        uint256 amount,
        uint64 fundedAt,
        uint64 dueDate
    );

    /// @notice Emitted on every payment toward a loan, including partial and final payments.
    /// @param loanId Identifier of the loan being repaid.
    /// @param amountPaid Amount transferred by this payment, in stablecoin base units.
    /// @param onTime True when the payment arrived on or before the due date it settles.
    event LoanRepaid(uint256 indexed loanId, uint256 amountPaid, bool onTime);

    /// @notice Emitted when an overdue loan is marked as defaulted.
    /// @param loanId Identifier of the defaulted loan.
    /// @param borrower Address that failed to repay.
    /// @param outstandingAmount Amount still unpaid at the moment of the mark, in base units.
    event LoanDefaulted(
        uint256 indexed loanId, address indexed borrower, uint256 outstandingAmount
    );
}
