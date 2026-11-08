// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {MockStablecoin} from "../src/MockStablecoin.sol";

contract MockStablecoinTest is Test {
    MockStablecoin internal token;
    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal callCap;
    uint256 internal mintToCap;
    uint256 internal addressCap;

    function setUp() public {
        token = new MockStablecoin(admin);
        callCap = token.MAX_MINT_PER_CALL();
        mintToCap = token.MAX_MINT_TO_PER_CALL();
        addressCap = token.MAX_MINT_PER_ADDRESS();
    }

    function test_Metadata() public view {
        assertEq(token.decimals(), 6);
        assertEq(token.name(), "LatiFi Test USD");
        assertEq(token.symbol(), "tUSD");
    }

    function test_CapsAreDocumentedValues() public view {
        assertEq(callCap, 1_000e6);
        assertEq(mintToCap, 10_000e6);
        assertEq(addressCap, 10_000e6);
    }

    function test_Mint_CreditsTheCallerAndTracksTotal() public {
        vm.prank(alice);
        token.mint(250e6);

        assertEq(token.balanceOf(alice), 250e6);
        assertEq(token.mintedTo(alice), 250e6);
        assertEq(token.totalSupply(), 250e6);
    }

    function test_Mint_AcceptsExactlyTheCallCap() public {
        vm.prank(alice);
        token.mint(callCap);
        assertEq(token.balanceOf(alice), callCap);
    }

    function test_Mint_RevertsAboveTheCallCap() public {
        vm.expectRevert(
            abi.encodeWithSelector(MockStablecoin.MintExceedsCallCap.selector, callCap + 1, callCap)
        );
        vm.prank(alice);
        token.mint(callCap + 1);
    }

    function test_MintTo_RevertsWithoutMinterRole() public {
        bytes32 role = token.MINTER_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, role
            )
        );
        vm.prank(alice);
        token.mintTo(bob, 1e6);
    }

    function test_MintTo_AdminMintsUpToItsCap() public {
        vm.prank(admin);
        token.mintTo(alice, mintToCap);
        assertEq(token.balanceOf(alice), mintToCap);
        assertEq(token.mintedTo(alice), mintToCap);
    }

    function test_MintTo_RevertsAboveItsCap() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                MockStablecoin.MintExceedsCallCap.selector, mintToCap + 1, mintToCap
            )
        );
        vm.prank(admin);
        token.mintTo(alice, mintToCap + 1);
    }

    function test_AddressCap_TenPublicMintsFillAnAddressAndTheNextOneReverts() public {
        vm.startPrank(alice);
        for (uint256 i = 0; i < 10; i++) {
            token.mint(callCap);
        }
        assertEq(token.balanceOf(alice), addressCap);

        vm.expectRevert(
            abi.encodeWithSelector(MockStablecoin.MintExceedsAddressCap.selector, alice, 1, 0)
        );
        token.mint(1);
        vm.stopPrank();
    }

    function test_AddressCap_ReportsTheExactRemainingAfterAPartialFill() public {
        vm.prank(alice);
        token.mint(400e6);

        uint256 remaining = addressCap - 400e6;
        vm.expectRevert(
            abi.encodeWithSelector(
                MockStablecoin.MintExceedsAddressCap.selector, alice, remaining + 1, remaining
            )
        );
        vm.prank(admin);
        token.mintTo(alice, remaining + 1);

        vm.prank(admin);
        token.mintTo(alice, remaining);
        assertEq(token.balanceOf(alice), addressCap);
    }

    function test_AddressCap_IsSharedByBothPaths() public {
        vm.prank(admin);
        token.mintTo(alice, mintToCap);

        vm.expectRevert(
            abi.encodeWithSelector(MockStablecoin.MintExceedsAddressCap.selector, alice, 1e6, 0)
        );
        vm.prank(alice);
        token.mint(1e6);
    }

    function test_AddressCap_IsPerRecipient() public {
        vm.prank(admin);
        token.mintTo(alice, mintToCap);

        vm.prank(bob);
        token.mint(callCap);
        assertEq(token.balanceOf(bob), callCap);
    }

    function test_Constructor_RevertsOnZeroAdmin() public {
        vm.expectRevert(MockStablecoin.ZeroAdmin.selector);
        new MockStablecoin(address(0));
    }

    function test_Constructor_GrantsBothRolesToTheAdmin() public view {
        assertTrue(token.hasRole(token.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(token.hasRole(token.MINTER_ROLE(), admin));
    }

    function test_GrantRole_RevertsForANonAdmin() public {
        bytes32 minter = token.MINTER_ROLE();
        bytes32 adminRole = token.DEFAULT_ADMIN_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, adminRole
            )
        );
        vm.prank(alice);
        token.grantRole(minter, alice);
    }

    function test_Roles_AdminCanGrantAndRevokeTheMinterRole() public {
        bytes32 minter = token.MINTER_ROLE();

        vm.prank(admin);
        token.grantRole(minter, alice);
        vm.prank(alice);
        token.mintTo(bob, 5e6);
        assertEq(token.balanceOf(bob), 5e6);

        vm.prank(admin);
        token.revokeRole(minter, alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, minter
            )
        );
        vm.prank(alice);
        token.mintTo(bob, 5e6);
    }

    function testFuzz_Mint_NeverExceedsTheAddressCap(uint256[12] calldata amounts) public {
        vm.startPrank(alice);
        for (uint256 i = 0; i < amounts.length; i++) {
            uint256 amount = bound(amounts[i], 0, callCap);
            uint256 remaining = addressCap - token.mintedTo(alice);
            if (amount > remaining) {
                vm.expectRevert(
                    abi.encodeWithSelector(
                        MockStablecoin.MintExceedsAddressCap.selector, alice, amount, remaining
                    )
                );
                token.mint(amount);
            } else {
                token.mint(amount);
            }
            assertLe(token.balanceOf(alice), addressCap);
        }
        vm.stopPrank();
    }
}
