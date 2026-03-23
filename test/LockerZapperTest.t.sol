// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {LockerZapper} from "../src/LockerZapper.sol";
import {LockedyvUSD} from "../src/LockedyvUSD.sol";
import {IVault} from "@yearn-vaults/interfaces/IVault.sol";
import {IVaultFactory} from "@yearn-vaults/interfaces/IVaultFactory.sol";
import {Roles} from "@yearn-vaults/interfaces/Roles.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Mock4626Strategy} from "./mocks/Mock4626Strategy.sol";
import {Token} from "@yearn-vaults/test/Token.sol";

contract LockerZapperTest is Test {
    // Core contracts
    LockerZapper public zapper;
    LockedyvUSD public lockedVault;
    IVault public yvUSD;
    IVaultFactory public vaultFactory;
    IERC20 public asset;

    // Addresses
    address constant VAULT_FACTORY = 0x770D0d1Fb036483Ed4AbB6d53c1C88fb277D812F;
    address public governance;
    address public management;

    // Test users
    address public alice;
    address public bob;

    // Test constants
    uint256 constant COOLDOWN_DURATION = 14 days;
    uint256 constant WITHDRAWAL_WINDOW = 7 days;
    uint256 constant INITIAL_DEPOSIT = 1_000_000e6;
    uint256 constant TEST_AMOUNT = 10_000e6;

    event ZapIn(address indexed user, uint256 indexed assetAmount, uint256 indexed lockedShares, address staking);

    event ZapOut(address indexed user, uint256 indexed lockedShares, uint256 indexed assetAmount, address staking);

    function setUp() public {
        // Setup addresses
        governance = makeAddr("governance");
        management = makeAddr("management");
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        // Label addresses
        vm.label(governance, "Governance");
        vm.label(management, "Management");
        vm.label(alice, "Alice");
        vm.label(bob, "Bob");

        // Setup vault factory
        vaultFactory = IVaultFactory(VAULT_FACTORY);
        vm.label(VAULT_FACTORY, "VaultFactory");

        // Use USDC as asset
        address USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
        asset = IERC20(USDC);
        vm.label(address(asset), "USDC");

        // Deploy yvUSD vault
        vm.startPrank(management);
        yvUSD =
            IVault(vaultFactory.deploy_new_vault(address(asset), "yvUSD Test Vault", "yvUSD-TEST", management, 7 days));
        vm.label(address(yvUSD), "yvUSD");

        // Deploy LockedyvUSD
        lockedVault = new LockedyvUSD(address(yvUSD), "Locked yvUSD");
        vm.label(address(lockedVault), "LockedyvUSD");

        // Configure vault
        yvUSD.set_role(management, Roles.ALL);
        yvUSD.set_deposit_limit(type(uint256).max);
        yvUSD.set_accountant(address(lockedVault));
        vm.stopPrank();

        // Deploy zapper
        zapper = new LockerZapper(governance);
        vm.label(address(zapper), "LockerZapper");

        // Fund test users
        deal(address(asset), alice, INITIAL_DEPOSIT);
        deal(address(asset), bob, INITIAL_DEPOSIT);
    }

    /*//////////////////////////////////////////////////////////////
                            ZAP IN TESTS
    //////////////////////////////////////////////////////////////*/

    function test_zapIn_basic() public {
        vm.startPrank(alice);
        asset.approve(address(zapper), TEST_AMOUNT);

        uint256 lockedShares = zapper.zapIn(address(lockedVault), TEST_AMOUNT, alice);
        vm.stopPrank();

        assertGt(lockedShares, 0, "Should receive locked shares");
        assertEq(IERC20(address(lockedVault)).balanceOf(alice), lockedShares, "Alice should have locked shares");
        assertEq(asset.balanceOf(alice), INITIAL_DEPOSIT - TEST_AMOUNT, "Asset should be deducted");
    }

    function test_zapIn_defaultReceiver() public {
        vm.startPrank(alice);
        asset.approve(address(zapper), TEST_AMOUNT);

        uint256 lockedShares = zapper.zapIn(address(lockedVault), TEST_AMOUNT);
        vm.stopPrank();

        assertGt(lockedShares, 0, "Should receive locked shares");
        assertEq(IERC20(address(lockedVault)).balanceOf(alice), lockedShares, "Alice should have locked shares");
    }

    function test_zapIn_maxAmount() public {
        vm.startPrank(alice);
        asset.approve(address(zapper), type(uint256).max);

        uint256 lockedShares = zapper.zapIn(address(lockedVault), type(uint256).max);
        vm.stopPrank();

        assertGt(lockedShares, 0, "Should receive locked shares");
        assertEq(asset.balanceOf(alice), 0, "All assets should be deposited");
    }

    function test_zapIn_differentReceiver() public {
        vm.startPrank(alice);
        asset.approve(address(zapper), TEST_AMOUNT);

        uint256 lockedShares = zapper.zapIn(address(lockedVault), TEST_AMOUNT, bob);
        vm.stopPrank();

        assertGt(lockedShares, 0, "Should receive locked shares");
        assertEq(IERC20(address(lockedVault)).balanceOf(bob), lockedShares, "Bob should have locked shares");
        assertEq(IERC20(address(lockedVault)).balanceOf(alice), 0, "Alice should have no locked shares");
    }

    function test_zapIn_emitsEvent() public {
        vm.startPrank(alice);
        asset.approve(address(zapper), TEST_AMOUNT);

        // We expect the ZapIn event, but we can't predict exact lockedShares
        vm.expectEmit(true, true, false, false);
        emit ZapIn(alice, TEST_AMOUNT, 0, address(lockedVault));

        zapper.zapIn(address(lockedVault), TEST_AMOUNT, alice);
        vm.stopPrank();
    }

    function test_zapIn_revertZeroAmount() public {
        vm.startPrank(alice);
        asset.approve(address(zapper), TEST_AMOUNT);

        vm.expectRevert("Amount must be > 0");
        zapper.zapIn(address(lockedVault), 0, alice);
        vm.stopPrank();
    }

    function test_zapIn_revertZeroReceiver() public {
        vm.startPrank(alice);
        asset.approve(address(zapper), TEST_AMOUNT);

        vm.expectRevert("Invalid receiver");
        zapper.zapIn(address(lockedVault), TEST_AMOUNT, address(0));
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                            ZAP OUT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_zapOut_basic() public {
        // First zap in
        vm.startPrank(alice);
        asset.approve(address(zapper), TEST_AMOUNT);
        uint256 lockedShares = zapper.zapIn(address(lockedVault), TEST_AMOUNT, alice);

        // Start cooldown
        lockedVault.startCooldown(lockedShares);

        // Warp past cooldown
        vm.warp(block.timestamp + COOLDOWN_DURATION + 1 days);

        // Approve zapper to spend locked shares
        IERC20(address(lockedVault)).approve(address(zapper), lockedShares);

        uint256 assetsBefore = asset.balanceOf(alice);
        uint256 assetsReceived = zapper.zapOut(address(lockedVault), lockedShares, alice);
        vm.stopPrank();

        assertGt(assetsReceived, 0, "Should receive assets");
        assertEq(asset.balanceOf(alice), assetsBefore + assetsReceived, "Assets should be received");
        assertEq(IERC20(address(lockedVault)).balanceOf(alice), 0, "Should have no locked shares left");
    }

    function test_zapOut_defaultReceiver() public {
        // First zap in
        vm.startPrank(alice);
        asset.approve(address(zapper), TEST_AMOUNT);
        uint256 lockedShares = zapper.zapIn(address(lockedVault), TEST_AMOUNT);

        // Start cooldown
        lockedVault.startCooldown(lockedShares);

        // Warp past cooldown
        vm.warp(block.timestamp + COOLDOWN_DURATION + 1 days);

        // Approve and zap out
        IERC20(address(lockedVault)).approve(address(zapper), lockedShares);

        uint256 assetsBefore = asset.balanceOf(alice);
        uint256 assetsReceived = zapper.zapOut(address(lockedVault), lockedShares);
        vm.stopPrank();

        assertGt(assetsReceived, 0, "Should receive assets");
        assertEq(asset.balanceOf(alice), assetsBefore + assetsReceived, "Assets should be received");
    }

    function test_zapOut_maxShares() public {
        // First zap in
        vm.startPrank(alice);
        asset.approve(address(zapper), TEST_AMOUNT);
        uint256 lockedShares = zapper.zapIn(address(lockedVault), TEST_AMOUNT);

        // Start cooldown for all shares
        lockedVault.startCooldown(lockedShares);

        // Warp past cooldown
        vm.warp(block.timestamp + COOLDOWN_DURATION + 1 days);

        // Approve and zap out with max
        IERC20(address(lockedVault)).approve(address(zapper), type(uint256).max);

        uint256 assetsReceived = zapper.zapOut(address(lockedVault), type(uint256).max);
        vm.stopPrank();

        assertGt(assetsReceived, 0, "Should receive assets");
        assertEq(IERC20(address(lockedVault)).balanceOf(alice), 0, "Should have no locked shares left");
    }

    function test_zapOut_maxShares_usesMaxWithdrawToAvoidDust() public {
        vm.startPrank(alice);
        asset.approve(address(zapper), TEST_AMOUNT);
        uint256 aliceShares = zapper.zapIn(address(lockedVault), TEST_AMOUNT);
        vm.stopPrank();

        vm.startPrank(bob);
        asset.approve(address(zapper), TEST_AMOUNT);
        zapper.zapIn(address(lockedVault), TEST_AMOUNT);
        vm.stopPrank();

        vm.startPrank(management);
        IVault(address(lockedVault)).setProfitMaxUnlockTime(0);
        deal(address(asset), management, 1);
        asset.approve(address(yvUSD), 1);
        uint256 donatedVaultShares = yvUSD.deposit(1, management);
        IERC20(address(yvUSD)).transfer(address(lockedVault), donatedVaultShares);
        lockedVault.report();
        vm.stopPrank();

        vm.startPrank(alice);
        lockedVault.startCooldown(aliceShares);
        vm.warp(block.timestamp + COOLDOWN_DURATION + 1 days);

        uint256 maxWithdrawAssets = IERC4626(address(lockedVault)).maxWithdraw(alice);
        uint256 maxRedeemShares = IERC4626(address(lockedVault)).maxRedeem(alice);

        assertEq(maxWithdrawAssets, TEST_AMOUNT, "maxWithdraw should preserve the full asset exit");
        assertEq(maxRedeemShares, aliceShares - 1, "maxRedeem rounds down and leaves dust");

        IERC20(address(lockedVault)).approve(address(zapper), type(uint256).max);

        uint256 assetsReceived = zapper.zapOut(address(lockedVault), type(uint256).max);
        vm.stopPrank();

        assertEq(assetsReceived, TEST_AMOUNT, "Should withdraw the full asset amount");
        assertEq(IERC20(address(lockedVault)).balanceOf(alice), 0, "Should burn all locked shares");
    }

    function test_zapOut_differentReceiver() public {
        // First zap in
        vm.startPrank(alice);
        asset.approve(address(zapper), TEST_AMOUNT);
        uint256 lockedShares = zapper.zapIn(address(lockedVault), TEST_AMOUNT);

        // Start cooldown
        lockedVault.startCooldown(lockedShares);

        // Warp past cooldown
        vm.warp(block.timestamp + COOLDOWN_DURATION + 1 days);

        // Approve and zap out to bob
        IERC20(address(lockedVault)).approve(address(zapper), lockedShares);

        uint256 bobAssetsBefore = asset.balanceOf(bob);
        uint256 assetsReceived = zapper.zapOut(address(lockedVault), lockedShares, bob);
        vm.stopPrank();

        assertGt(assetsReceived, 0, "Should receive assets");
        assertEq(asset.balanceOf(bob), bobAssetsBefore + assetsReceived, "Bob should receive assets");
    }

    function test_zapOut_revertBeforeCooldown() public {
        // First zap in
        vm.startPrank(alice);
        asset.approve(address(zapper), TEST_AMOUNT);
        uint256 lockedShares = zapper.zapIn(address(lockedVault), TEST_AMOUNT);

        // Start cooldown but don't warp
        lockedVault.startCooldown(lockedShares);

        // Approve zapper
        IERC20(address(lockedVault)).approve(address(zapper), lockedShares);

        // Should revert because cooldown not complete
        vm.expectRevert("ERC4626: redeem more than max");
        zapper.zapOut(address(lockedVault), lockedShares);
        vm.stopPrank();
    }

    function test_zapOut_revertNoCooldown() public {
        // First zap in
        vm.startPrank(alice);
        asset.approve(address(zapper), TEST_AMOUNT);
        uint256 lockedShares = zapper.zapIn(address(lockedVault), TEST_AMOUNT);

        // Don't start cooldown

        // Approve zapper
        IERC20(address(lockedVault)).approve(address(zapper), lockedShares);

        // Should revert because no cooldown started
        vm.expectRevert("ERC4626: redeem more than max");
        zapper.zapOut(address(lockedVault), lockedShares);
        vm.stopPrank();
    }

    function test_zapOut_revertZeroShares() public {
        vm.startPrank(alice);
        vm.expectRevert("Shares must be > 0");
        zapper.zapOut(address(lockedVault), 0, alice);
        vm.stopPrank();
    }

    function test_zapOut_revertZeroReceiver() public {
        vm.startPrank(alice);
        vm.expectRevert("Invalid receiver");
        zapper.zapOut(address(lockedVault), TEST_AMOUNT, address(0));
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                            PREVIEW TESTS
    //////////////////////////////////////////////////////////////*/

    function test_previewZapIn() public view {
        uint256 preview = zapper.previewZapIn(address(lockedVault), TEST_AMOUNT);
        assertGt(preview, 0, "Preview should return positive value");
    }

    function test_previewZapOut() public {
        // First zap in to have some shares
        vm.startPrank(alice);
        asset.approve(address(zapper), TEST_AMOUNT);
        uint256 lockedShares = zapper.zapIn(address(lockedVault), TEST_AMOUNT);
        vm.stopPrank();

        uint256 preview = zapper.previewZapOut(address(lockedVault), lockedShares);
        assertGt(preview, 0, "Preview should return positive value");
    }

    /*//////////////////////////////////////////////////////////////
                        INTEGRATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_fullCycle_zapInCooldownZapOut() public {
        uint256 initialBalance = asset.balanceOf(alice);

        // Zap in
        vm.startPrank(alice);
        asset.approve(address(zapper), TEST_AMOUNT);
        uint256 lockedShares = zapper.zapIn(address(lockedVault), TEST_AMOUNT);

        // Start cooldown
        lockedVault.startCooldown(lockedShares);

        // Warp past cooldown
        vm.warp(block.timestamp + COOLDOWN_DURATION + 1 days);

        // Zap out
        IERC20(address(lockedVault)).approve(address(zapper), lockedShares);
        uint256 assetsReceived = zapper.zapOut(address(lockedVault), lockedShares);
        vm.stopPrank();

        // Should get back approximately same amount (no gains/losses in this simple test)
        assertApproxEqRel(assetsReceived, TEST_AMOUNT, 0.01e18, "Should get back approximately same amount");
        assertEq(asset.balanceOf(alice), initialBalance - TEST_AMOUNT + assetsReceived, "Balance should be correct");
    }

    function test_multipleUsers_zapInOut() public {
        // Alice zaps in
        vm.startPrank(alice);
        asset.approve(address(zapper), TEST_AMOUNT);
        uint256 aliceShares = zapper.zapIn(address(lockedVault), TEST_AMOUNT);
        lockedVault.startCooldown(aliceShares);
        vm.stopPrank();

        // Bob zaps in
        vm.startPrank(bob);
        asset.approve(address(zapper), TEST_AMOUNT * 2);
        uint256 bobShares = zapper.zapIn(address(lockedVault), TEST_AMOUNT * 2);
        lockedVault.startCooldown(bobShares);
        vm.stopPrank();

        // Warp past cooldown
        vm.warp(block.timestamp + COOLDOWN_DURATION + 1 days);

        // Both zap out
        vm.startPrank(alice);
        IERC20(address(lockedVault)).approve(address(zapper), aliceShares);
        uint256 aliceAssets = zapper.zapOut(address(lockedVault), aliceShares);
        vm.stopPrank();

        vm.startPrank(bob);
        IERC20(address(lockedVault)).approve(address(zapper), bobShares);
        uint256 bobAssets = zapper.zapOut(address(lockedVault), bobShares);
        vm.stopPrank();

        // Bob should get approximately 2x Alice (since he deposited 2x)
        assertApproxEqRel(bobAssets, aliceAssets * 2, 0.01e18, "Bob should get 2x Alice's assets");
    }

    function test_zapper_canBeReusedForYvBTCStyleVault() public {
        Token wbtc = new Token("WBTC", 8);
        Mock4626Strategy yvBTC = new Mock4626Strategy(IERC20(address(wbtc)), "yvBTC Test Vault", "yvBTC-TEST");
        LockedyvUSD lockedYvBTC = new LockedyvUSD(address(yvBTC), "Locked yvBTC");
        address satoshi = makeAddr("satoshi");
        uint256 depositAmount = 1e8;

        wbtc.mint(satoshi, depositAmount);

        vm.startPrank(satoshi);
        IERC20(address(wbtc)).approve(address(zapper), depositAmount);

        uint256 lockedShares = zapper.zapIn(address(lockedYvBTC), depositAmount);
        lockedYvBTC.startCooldown(lockedShares);

        vm.warp(block.timestamp + COOLDOWN_DURATION + 1 days);

        IERC20(address(lockedYvBTC)).approve(address(zapper), type(uint256).max);

        uint256 assetsReceived = zapper.zapOut(address(lockedYvBTC), type(uint256).max);
        vm.stopPrank();

        assertEq(assetsReceived, depositAmount, "Should round-trip the BTC-style vault");
        assertEq(IERC20(address(lockedYvBTC)).balanceOf(satoshi), 0, "Should clear locked shares");
        assertEq(wbtc.balanceOf(satoshi), depositAmount, "Should return the base asset");
    }

    function test_sweep_governanceCanRecoverDust() public {
        uint256 dust = 123e6;
        address receiver = makeAddr("receiver");

        deal(address(asset), address(zapper), dust);

        vm.prank(governance);
        zapper.sweep(asset, receiver);

        assertEq(asset.balanceOf(address(zapper)), 0, "Zapper should not retain dust");
        assertEq(asset.balanceOf(receiver), dust, "Receiver should get swept dust");
    }

    function test_sweep_revertNonGovernance() public {
        deal(address(asset), address(zapper), 1);

        vm.prank(alice);
        vm.expectRevert("!governance");
        zapper.sweep(asset, alice);
    }
}
