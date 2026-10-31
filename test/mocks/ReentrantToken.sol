// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Called on the sender of a transfer before the balances change (ERC-777 style).
interface IHookSender {
    function tokensToSend(address from, address to, uint256 amount) external;
}

/// @notice Called on the recipient of a transfer after the balances change (ERC-777 style).
interface IHookReceiver {
    function tokensReceived(address from, address to, uint256 amount) external;
}

/// @notice Test-only token that hands control to contract accounts in the middle of a transfer.
/// It models the reentrancy surface of ERC-777 and similar hook tokens. Never imported by src/.
contract ReentrantToken is ERC20 {
    constructor() ERC20("Hooked", "HOOK") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && from.code.length > 0) {
            IHookSender(from).tokensToSend(from, to, value);
        }
        super._update(from, to, value);
        if (to != address(0) && to.code.length > 0) {
            IHookReceiver(to).tokensReceived(from, to, value);
        }
    }
}
