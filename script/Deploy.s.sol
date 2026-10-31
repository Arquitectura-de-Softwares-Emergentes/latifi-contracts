// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Script, console} from "forge-std/Script.sol";
import {LoanBook} from "../src/LoanBook.sol";
import {MockStablecoin} from "../src/MockStablecoin.sol";

/// @notice Deploys MockStablecoin and then LoanBook on Polygon Amoy.
/// @dev Holds no key material and reads no environment variable. The signer comes from the CLI
/// (--account or --keystore on the machine that owns the key). Without --broadcast it only
/// simulates, and chain id 31337 is the in-memory simulation.
contract Deploy is Script {
    uint256 internal constant AMOY_CHAIN_ID = 80002;
    uint256 internal constant LOCAL_CHAIN_ID = 31337;

    function run() external returns (MockStablecoin token, LoanBook book) {
        require(
            block.chainid == AMOY_CHAIN_ID || block.chainid == LOCAL_CHAIN_ID, "unexpected chain"
        );

        vm.startBroadcast();
        // Inside run(), msg.sender is the default script sender. The broadcaster is read after
        // startBroadcast.
        (, address deployer,) = vm.readCallers();
        token = new MockStablecoin(deployer);
        book = new LoanBook(token);
        vm.stopBroadcast();

        console.log("deployer", deployer);
        console.log("MockStablecoin", address(token));
        console.log("LoanBook", address(book));
    }
}
