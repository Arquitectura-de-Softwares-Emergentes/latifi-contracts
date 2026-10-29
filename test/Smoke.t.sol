// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";

contract SmokeTest is Test {
    function test_ChainIsNotMainnet() public view {
        assertTrue(block.chainid != 1, "Ethereum mainnet is forbidden");
        assertTrue(block.chainid != 137, "Polygon PoS mainnet is forbidden");
    }
}
