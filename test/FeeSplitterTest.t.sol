// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {FeeSplitter} from "../src/FeeSplitter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract FeeSplitterTest is Test {
    FeeSplitter public splitter;
    ERC20Mock public token;

    address public governance;
    address public alice;
    address public bob;
    address public charlie;

    uint256 constant BASIS_POINTS = 10_000;
    uint256 constant TEST_AMOUNT = 100_000e18;

    event ReceiverAdded(address indexed token, address indexed receiver);
    event ReceiverRemoved(address indexed token, address indexed receiver);
    event SplitUpdated(address indexed token, address indexed receiver, uint256 newSplit, uint256 newTotalSplit);
    event TokenDistributed(address indexed token, uint256 amount);

    function setUp() public {
        governance = makeAddr("governance");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");

        vm.label(governance, "Governance");
        vm.label(alice, "Alice");
        vm.label(bob, "Bob");
        vm.label(charlie, "Charlie");

        // Deploy splitter
        splitter = new FeeSplitter(governance);
        vm.label(address(splitter), "FeeSplitter");

        // Deploy mock token
        token = new ERC20Mock();
        vm.label(address(token), "TestToken");

        // Mint tokens to splitter for testing
        token.mint(address(splitter), TEST_AMOUNT);
    }

    /*//////////////////////////////////////////////////////////////
                            SETUP TESTS
    //////////////////////////////////////////////////////////////*/

    function test_setup() public view {
        assertEq(splitter.governance(), governance, "Governance should be set");
        assertEq(token.balanceOf(address(splitter)), TEST_AMOUNT, "Splitter should have tokens");
    }

    /*//////////////////////////////////////////////////////////////
                        UPDATE SPLIT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_updateSplit_addReceiver() public {
        vm.prank(governance);
        splitter.updateSplit(address(token), alice, 5000); // 50%

        assertTrue(splitter.containsReceiver(address(token), alice), "Alice should be a receiver");
        assertEq(splitter.getReceiverSplit(address(token), alice), 5000, "Alice should have 50% split");
        assertEq(splitter.getTotalSplit(address(token)), 5000, "Total split should be 50%");
    }

    function test_updateSplit_addMultipleReceivers() public {
        vm.startPrank(governance);
        splitter.updateSplit(address(token), alice, 3000); // 30%
        splitter.updateSplit(address(token), bob, 4000); // 40%
        splitter.updateSplit(address(token), charlie, 3000); // 30%
        vm.stopPrank();

        assertEq(splitter.getTotalSplit(address(token)), 10_000, "Total split should be 100%");
        assertEq(splitter.getReceiversLength(address(token)), 3, "Should have 3 receivers");
    }

    function test_updateSplit_updateExistingReceiver() public {
        vm.startPrank(governance);
        splitter.updateSplit(address(token), alice, 5000); // 50%
        splitter.updateSplit(address(token), alice, 7000); // 70%
        vm.stopPrank();

        assertEq(splitter.getReceiverSplit(address(token), alice), 7000, "Alice should have 70% split");
        assertEq(splitter.getTotalSplit(address(token)), 7000, "Total split should be 70%");
    }

    function test_updateSplit_emitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit ReceiverAdded(address(token), alice);

        vm.expectEmit(true, true, true, true);
        emit SplitUpdated(address(token), alice, 5000, 5000);

        vm.prank(governance);
        splitter.updateSplit(address(token), alice, 5000);
    }

    function test_updateSplit_revertNotGovernance() public {
        vm.expectRevert();
        splitter.updateSplit(address(token), alice, 5000);
    }

    function test_updateSplit_revertInvalidReceiver() public {
        vm.startPrank(governance);
        vm.expectRevert("invalid receiver");
        splitter.updateSplit(address(token), address(0), 5000);

        vm.expectRevert("invalid receiver");
        splitter.updateSplit(address(token), address(splitter), 5000);
        vm.stopPrank();
    }

    function test_updateSplit_revertExceedsMax() public {
        vm.startPrank(governance);
        splitter.updateSplit(address(token), alice, 5000);

        vm.expectRevert("Total split exceeds maximum");
        splitter.updateSplit(address(token), bob, 6000); // Would exceed 100%
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                        REMOVE RECEIVER TESTS
    //////////////////////////////////////////////////////////////*/

    function test_removeReceiver() public {
        vm.startPrank(governance);
        splitter.updateSplit(address(token), alice, 5000);
        splitter.updateSplit(address(token), bob, 5000);

        splitter.removeReceiver(address(token), alice);
        vm.stopPrank();

        assertFalse(splitter.containsReceiver(address(token), alice), "Alice should not be a receiver");
        assertTrue(splitter.containsReceiver(address(token), bob), "Bob should still be a receiver");
        assertEq(splitter.getTotalSplit(address(token)), 5000, "Total split should be 50%");
    }

    function test_removeReceiver_emitsEvent() public {
        vm.startPrank(governance);
        splitter.updateSplit(address(token), alice, 5000);
        vm.stopPrank();

        vm.startPrank(governance);
        vm.expectEmit(true, true, true, true);
        emit ReceiverRemoved(address(token), alice);

        splitter.removeReceiver(address(token), alice);
        vm.stopPrank();
    }

    function test_removeReceiver_revertNotAdded() public {
        vm.prank(governance);
        vm.expectRevert("Receiver not added");
        splitter.removeReceiver(address(token), alice);
    }

    /*//////////////////////////////////////////////////////////////
                        DISTRIBUTE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_distribute_basic() public {
        vm.startPrank(governance);
        splitter.updateSplit(address(token), alice, 6000); // 60%
        splitter.updateSplit(address(token), bob, 4000); // 40%
        vm.stopPrank();

        uint256 aliceBalanceBefore = token.balanceOf(alice);
        uint256 bobBalanceBefore = token.balanceOf(bob);

        splitter.distribute(address(token));

        assertEq(
            token.balanceOf(alice), aliceBalanceBefore + (TEST_AMOUNT * 6000) / BASIS_POINTS, "Alice should receive 60%"
        );
        assertEq(token.balanceOf(bob), bobBalanceBefore + (TEST_AMOUNT * 4000) / BASIS_POINTS, "Bob should receive 40%");
        assertEq(token.balanceOf(address(splitter)), 0, "Splitter should have no tokens left");
    }

    function test_distribute_emitsEvent() public {
        vm.startPrank(governance);
        splitter.updateSplit(address(token), alice, 10_000);
        vm.stopPrank();

        vm.expectEmit(true, true, false, true);
        emit TokenDistributed(address(token), TEST_AMOUNT);

        splitter.distribute(address(token));
    }

    function test_distribute_revertNotConfigured() public {
        vm.expectRevert("Token split not configured");
        splitter.distribute(address(token));
    }

    function test_distributeMany() public {
        ERC20Mock token2 = new ERC20Mock();
        token2.mint(address(splitter), TEST_AMOUNT);

        vm.startPrank(governance);
        splitter.updateSplit(address(token), alice, 10_000);
        splitter.updateSplit(address(token2), bob, 10_000);
        vm.stopPrank();

        address[] memory tokens = new address[](2);
        tokens[0] = address(token);
        tokens[1] = address(token2);

        splitter.distributeMany(tokens);

        assertEq(token.balanceOf(alice), TEST_AMOUNT, "Alice should receive token1");
        assertEq(token2.balanceOf(bob), TEST_AMOUNT, "Bob should receive token2");
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW TESTS
    //////////////////////////////////////////////////////////////*/

    function test_getReceiversAndSplits() public {
        vm.startPrank(governance);
        splitter.updateSplit(address(token), alice, 3000);
        splitter.updateSplit(address(token), bob, 7000);
        vm.stopPrank();

        (address[] memory receivers, uint256[] memory splits) = splitter.getReceiversAndSplits(address(token));

        assertEq(receivers.length, 2, "Should have 2 receivers");
        assertEq(splits.length, 2, "Should have 2 splits");

        // Check that alice and bob are in the receivers array
        bool foundAlice = false;
        bool foundBob = false;
        for (uint256 i = 0; i < receivers.length; i++) {
            if (receivers[i] == alice) {
                assertEq(splits[i], 3000, "Alice should have 30% split");
                foundAlice = true;
            }
            if (receivers[i] == bob) {
                assertEq(splits[i], 7000, "Bob should have 70% split");
                foundBob = true;
            }
        }
        assertTrue(foundAlice && foundBob, "Should find both receivers");
    }

    function test_getReceivers() public {
        vm.startPrank(governance);
        splitter.updateSplit(address(token), alice, 5000);
        splitter.updateSplit(address(token), bob, 5000);
        vm.stopPrank();

        address[] memory receivers = splitter.getReceivers(address(token));
        assertEq(receivers.length, 2, "Should have 2 receivers");
    }

    function test_isTokenConfigured() public {
        assertFalse(splitter.isTokenConfigured(address(token)), "Token should not be configured initially");

        vm.prank(governance);
        splitter.updateSplit(address(token), alice, 5000);

        assertTrue(splitter.isTokenConfigured(address(token)), "Token should be configured");
    }

    function test_getReceiverAt() public {
        vm.startPrank(governance);
        splitter.updateSplit(address(token), alice, 5000);
        splitter.updateSplit(address(token), bob, 5000);
        vm.stopPrank();

        address receiver0 = splitter.getReceiverAt(address(token), 0);
        address receiver1 = splitter.getReceiverAt(address(token), 1);

        assertTrue(
            (receiver0 == alice && receiver1 == bob) || (receiver0 == bob && receiver1 == alice),
            "Should return alice and bob"
        );
    }

    /*//////////////////////////////////////////////////////////////
                        RESCUE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_rescue() public {
        vm.prank(governance);
        bool success = splitter.rescue(address(token), alice);

        assertTrue(success, "Rescue should succeed");
        assertEq(token.balanceOf(alice), TEST_AMOUNT, "Alice should receive tokens");
        assertEq(token.balanceOf(address(splitter)), 0, "Splitter should have no tokens");
    }

    function test_rescue_revertNotGovernance() public {
        vm.expectRevert();
        splitter.rescue(address(token), alice);
    }
}
