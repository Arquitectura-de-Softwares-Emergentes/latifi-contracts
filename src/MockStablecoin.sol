// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title MockStablecoin
/// @notice Test dollar used on Polygon Amoy. It has no value and exists so that demo wallets can
/// fund themselves and run the loan cycle.
/// @dev Six decimals like the real stablecoins. Anyone can mint to their own wallet in small
/// steps, and the minter role can mint to any wallet in bigger steps. Both paths share one
/// cumulative cap per recipient. The role has no power over LoanBook.
contract MockStablecoin is ERC20, AccessControl {
    /// @notice Role allowed to call mintTo.
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    /// @notice Largest amount one public mint call can create, 1,000 tokens.
    uint256 public constant MAX_MINT_PER_CALL = 1_000e6;
    /// @notice Largest amount one mintTo call can create, 10,000 tokens.
    uint256 public constant MAX_MINT_TO_PER_CALL = 10_000e6;
    /// @notice Largest amount that can be minted to one address over time, 10,000 tokens.
    uint256 public constant MAX_MINT_PER_ADDRESS = 10_000e6;

    /// @notice Total amount minted to each address through both paths.
    mapping(address account => uint256 amount) public mintedTo;

    /// @notice The admin given to the constructor is the zero address.
    error ZeroAdmin();
    /// @notice The requested amount is above the cap of one call.
    error MintExceedsCallCap(uint256 requested, uint256 cap);
    /// @notice The requested amount does not fit in what the address can still receive.
    error MintExceedsAddressCap(address to, uint256 requested, uint256 remaining);

    /// @param admin Receives the default admin role and the minter role.
    constructor(address admin) ERC20("LatiFi Test USD", "tUSD") {
        if (admin == address(0)) revert ZeroAdmin();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(MINTER_ROLE, admin);
    }

    /// @notice Mints test tokens to the caller, up to 1,000 tokens per call.
    /// @param amount Amount in base units.
    function mint(uint256 amount) external {
        _capped(msg.sender, amount, MAX_MINT_PER_CALL);
    }

    /// @notice Mints test tokens to any address, up to 10,000 tokens per call. Minter role only.
    /// @param to Recipient of the tokens.
    /// @param amount Amount in base units.
    function mintTo(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        _capped(to, amount, MAX_MINT_TO_PER_CALL);
    }

    /// @notice Number of decimals, six like USDC.
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function _capped(address to, uint256 amount, uint256 callCap) private {
        if (amount > callCap) revert MintExceedsCallCap(amount, callCap);
        uint256 minted = mintedTo[to];
        uint256 remaining = MAX_MINT_PER_ADDRESS - minted;
        if (amount > remaining) revert MintExceedsAddressCap(to, amount, remaining);
        mintedTo[to] = minted + amount;
        _mint(to, amount);
    }
}
