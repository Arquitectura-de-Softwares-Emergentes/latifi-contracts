// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {ILoanEvents} from "../src/interfaces/ILoanEvents.sol";

/// @notice Pins the v0 event topics and the abi/loan-events.v0.json file.
/// @dev Changing a name, a type or the order of a field changes topic0 and breaks the indexer, so
/// any edit here must come with a changelog entry in docs/EVENTS.md.
contract LoanEventsAbiTest is Test {
    string private constant ABI_PATH = "abi/loan-events.v0.json";

    function test_LoanRequestedSelector() public pure {
        assertEq(
            ILoanEvents.LoanRequested.selector,
            keccak256("LoanRequested(uint256,address,uint256,uint16,uint32,uint8)")
        );
    }

    function test_LoanFundedSelector() public pure {
        assertEq(
            ILoanEvents.LoanFunded.selector,
            keccak256("LoanFunded(uint256,address,address,uint256,uint64,uint64)")
        );
    }

    function test_LoanRepaidSelector() public pure {
        assertEq(ILoanEvents.LoanRepaid.selector, keccak256("LoanRepaid(uint256,uint256,bool)"));
    }

    function test_LoanDefaultedSelector() public pure {
        assertEq(
            ILoanEvents.LoanDefaulted.selector, keccak256("LoanDefaulted(uint256,address,uint256)")
        );
    }

    function test_SelectorsAreDistinct() public pure {
        bytes32 a = ILoanEvents.LoanRequested.selector;
        bytes32 b = ILoanEvents.LoanFunded.selector;
        bytes32 c = ILoanEvents.LoanRepaid.selector;
        bytes32 d = ILoanEvents.LoanDefaulted.selector;
        assertTrue(a != b && a != c && a != d && b != c && b != d && c != d);
    }

    function test_JsonAbiHoldsExactlyFourEvents() public view {
        string memory json = vm.readFile(ABI_PATH);
        assertTrue(vm.keyExistsJson(json, "$[3]"), "the v0 ABI must hold four events");
        assertFalse(vm.keyExistsJson(json, "$[4]"), "the v0 ABI must not hold a fifth entry");
        // The file is sorted by event name, so the order below is fixed.
        assertEq(vm.parseJsonString(json, "$[0].name"), "LoanDefaulted");
        assertEq(vm.parseJsonString(json, "$[1].name"), "LoanFunded");
        assertEq(vm.parseJsonString(json, "$[2].name"), "LoanRepaid");
        assertEq(vm.parseJsonString(json, "$[3].name"), "LoanRequested");
        for (uint256 i = 0; i < 4; i++) {
            assertEq(
                vm.parseJsonString(json, string.concat("$[", vm.toString(i), "].type")), "event"
            );
        }
    }

    function test_LoanRepaidHasExactlyThreeFields() public view {
        string memory json = vm.readFile(ABI_PATH);
        // LoanRepaid sits at index 2 because the file is sorted by name.
        assertEq(vm.parseJsonString(json, "$[2].name"), "LoanRepaid");
        assertTrue(vm.keyExistsJson(json, "$[2].inputs[2]"), "LoanRepaid needs three fields");
        assertFalse(vm.keyExistsJson(json, "$[2].inputs[3]"), "LoanRepaid has a fourth field");
        assertEq(vm.parseJsonString(json, "$[2].inputs[0].name"), "loanId");
        assertEq(vm.parseJsonString(json, "$[2].inputs[1].name"), "amountPaid");
        assertEq(vm.parseJsonString(json, "$[2].inputs[2].name"), "onTime");
        assertTrue(vm.parseJsonBool(json, "$[2].inputs[0].indexed"), "loanId is indexed");
        assertFalse(vm.parseJsonBool(json, "$[2].inputs[1].indexed"), "amountPaid is not indexed");
        assertFalse(vm.parseJsonBool(json, "$[2].inputs[2].indexed"), "onTime is not indexed");
    }
}
