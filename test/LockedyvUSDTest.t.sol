// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {LockedVault} from "../src/LockedVault.sol";
import {ILockedVault} from "../src/interfaces/ILockedVault.sol";
import {IVault} from "@yearn-vaults/interfaces/IVault.sol";
import {IVaultFactory} from "@yearn-vaults/interfaces/IVaultFactory.sol";
import {Roles} from "@yearn-vaults/interfaces/Roles.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Mock4626Strategy} from "./mocks/Mock4626Strategy.sol";

contract LockedyvUSDTest is Test {
    ILockedVault public lockedVault;
    IVault public yvUSD;
    IVaultFactory public vaultFactory;
    IERC20 public asset;

    address constant VAULT_FACTORY = 0x770D0d1Fb036483Ed4AbB6d53c1C88fb277D812F;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    address public management;
    address public performanceFeeRecipient;
    address public alice;
    address public bob;
    address public attacker;

    uint256 constant COOLDOWN_DURATION = 14 days;
    uint256 constant MAX_COOLDOWN_DURATION = 30 days;
    uint256 constant TEST_AMOUNT = 10_000e6;
    uint256 constant INITIAL_DEPOSIT = 1_000_000e6;

    uint16 constant MANAGEMENT_FEE = 25;
    uint16 constant PERFORMANCE_FEE = 1_000;
    uint16 constant LOCKER_BONUS = 1_000;

    event CooldownStarted(address indexed user, uint256 indexed shares, uint256 indexed timestamp);

    function setUp() public {
        management = makeAddr("management");
        performanceFeeRecipient = makeAddr("performanceFeeRecipient");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        attacker = makeAddr("attacker");

        vm.label(management, "Management");
        vm.label(performanceFeeRecipient, "PerformanceFeeRecipient");
        vm.label(alice, "Alice");
        vm.label(bob, "Bob");
        vm.label(attacker, "Attacker");

        vaultFactory = IVaultFactory(VAULT_FACTORY);
        asset = IERC20(USDC);

        vm.startPrank(management);
        yvUSD =
            IVault(vaultFactory.deploy_new_vault(address(asset), "yvUSD Test Vault", "yvUSD-TEST", management, 7 days));

        lockedVault = ILockedVault(address(new LockedVault(address(yvUSD), "Locked Vault")));

        lockedVault.setPerformanceFee(0);
        lockedVault.setPerformanceFeeRecipient(performanceFeeRecipient);
        lockedVault.setProfitMaxUnlockTime(7 days);
        lockedVault.setFees(MANAGEMENT_FEE, PERFORMANCE_FEE, LOCKER_BONUS);
        lockedVault.setDoHealthCheck(false);
        lockedVault.setProfitLimitRatio(10_000);
        lockedVault.setLossLimitRatio(500);

        yvUSD.set_role(management, Roles.ALL);
        yvUSD.set_deposit_limit(type(uint256).max);
        yvUSD.set_accountant(address(lockedVault));
        vm.stopPrank();

        deal(address(asset), alice, INITIAL_DEPOSIT);
        deal(address(asset), bob, INITIAL_DEPOSIT);
        deal(address(asset), attacker, INITIAL_DEPOSIT);
    }

    function depositToLockedVault(address user, uint256 amount) internal returns (uint256 shares) {
        vm.startPrank(user);
        asset.approve(address(lockedVault), amount);
        shares = lockedVault.deposit(amount, user);
        vm.stopPrank();
    }

    function test_setup_usesUnderlyingAsset() public view {
        assertEq(lockedVault.asset(), address(asset), "asset should be USDC");
        assertEq(lockedVault.vault(), address(yvUSD), "vault should be yvUSD");
        assertEq(lockedVault.cooldownDuration(), COOLDOWN_DURATION);
        assertEq(
            lockedVault.MAX_COOLDOWN_DURATION(),
            MAX_COOLDOWN_DURATION,
            "max cooldown should be 30 days"
        );
    }

    function test_deposit_compoundsIntoWrappedVault() public {
        uint256 shares = depositToLockedVault(alice, TEST_AMOUNT);

        assertGt(shares, 0, "should mint strategy shares");
        assertEq(lockedVault.balanceOf(alice), shares, "alice should own shares");
        assertEq(asset.balanceOf(alice), INITIAL_DEPOSIT - TEST_AMOUNT);
        assertGt(yvUSD.balanceOf(address(lockedVault)), 0, "vault shares should be deployed");
    }

    function test_startCooldown_andWithdrawWithinWindow() public {
        uint256 shares = depositToLockedVault(alice, TEST_AMOUNT);

        vm.expectEmit(true, false, false, true);
        emit CooldownStarted(alice, shares, block.timestamp);

        vm.prank(alice);
        lockedVault.startCooldown(shares);

        vm.warp(block.timestamp + COOLDOWN_DURATION + 1 days);

        uint256 balanceBefore = asset.balanceOf(alice);
        vm.prank(alice);
        uint256 assetsOut = lockedVault.redeem(shares, alice, alice);

        assertGt(assetsOut, 0, "should receive assets");
        assertEq(asset.balanceOf(alice), balanceBefore + assetsOut);
        assertEq(lockedVault.balanceOf(alice), 0, "all shares should be gone");

        (,, uint256 coolingShares) = lockedVault.getCooldownStatus(alice);
        assertEq(coolingShares, 0, "cooldown should be cleared");
    }

    function test_redeem_revertsBeforeCooldownEnds() public {
        uint256 shares = depositToLockedVault(alice, TEST_AMOUNT);

        vm.prank(alice);
        lockedVault.startCooldown(shares);

        vm.prank(alice);
        vm.expectRevert("ERC4626: redeem more than max");
        lockedVault.redeem(shares, alice, alice);
    }

    function test_transferBlocksCoolingSharesButAllowsFreshShares() public {
        uint256 cooledShares = depositToLockedVault(alice, TEST_AMOUNT);

        vm.prank(alice);
        lockedVault.startCooldown(cooledShares);

        uint256 freshShares = depositToLockedVault(alice, TEST_AMOUNT);

        vm.prank(alice);
        bool success = lockedVault.transfer(bob, freshShares);
        assertTrue(success, "fresh shares should move");

        vm.prank(alice);
        vm.expectRevert("Cannot transfer shares in cooldown");
        lockedVault.transfer(bob, 1);
    }

    function test_zeroCooldownLetsUsersExitImmediately() public {
        vm.prank(management);
        lockedVault.setCooldownDuration(0);

        uint256 shares = depositToLockedVault(alice, TEST_AMOUNT);

        vm.prank(alice);
        uint256 assetsOut = lockedVault.redeem(shares, alice, alice);
        assertGt(assetsOut, 0, "should redeem without cooldown");
    }

    function test_onlyManagementCanUpdateCooldownConfig() public {
        vm.prank(attacker);
        vm.expectRevert("!management");
        lockedVault.setCooldownDuration(0);

        vm.prank(attacker);
        vm.expectRevert("!management");
        lockedVault.setWithdrawalWindow(2 days);

        vm.startPrank(management);
        lockedVault.setCooldownDuration(0);
        lockedVault.setWithdrawalWindow(2 days);
        vm.stopPrank();

        assertEq(lockedVault.cooldownDuration(), 0, "management should update cooldown");
        assertEq(lockedVault.withdrawalWindow(), 2 days, "management should update window");
    }

    function test_managementCannotSetCooldownAboveMax() public {
        vm.prank(management);
        vm.expectRevert("Cooldown duration too long");
        lockedVault.setCooldownDuration(MAX_COOLDOWN_DURATION + 1);
    }

    function test_shutdownBypassesCooldown() public {
        uint256 shares = depositToLockedVault(alice, TEST_AMOUNT);

        vm.prank(alice);
        lockedVault.startCooldown(shares);

        vm.prank(alice);
        vm.expectRevert("ERC4626: redeem more than max");
        lockedVault.redeem(shares, alice, alice);

        vm.prank(management);
        lockedVault.shutdownStrategy();

        vm.prank(alice);
        uint256 assetsOut = lockedVault.redeem(shares, alice, alice);
        assertGt(assetsOut, 0, "shutdown should bypass cooldown");
    }

    function test_processReportAccruesFeeShares_withoutStrategyDeposits() public {
        _depositDirectlyIntoWrappedVault(attacker, TEST_AMOUNT);

        address strategy = _deployMockStrategyWithDebt(TEST_AMOUNT);
        uint256 gain = TEST_AMOUNT / 10;
        deal(address(asset), strategy, TEST_AMOUNT + gain);

        vm.prank(management);
        yvUSD.process_report(strategy);

        uint256 accrued = lockedVault.feeShares();
        assertGt(accrued, 0, "fee shares should accrue");

        uint256 recipientBalanceBefore = yvUSD.balanceOf(performanceFeeRecipient);
        vm.prank(performanceFeeRecipient);
        lockedVault.withdrawFees(performanceFeeRecipient);

        assertEq(lockedVault.feeShares(), 0, "fee shares should be cleared");
        assertEq(
            yvUSD.balanceOf(performanceFeeRecipient),
            recipientBalanceBefore + accrued,
            "recipient should receive accrued yvUSD shares"
        );
    }

    function test_processReportPaysFeesImmediately_whenVaultSharesExist() public {
        depositToLockedVault(alice, TEST_AMOUNT);

        address strategy = _deployMockStrategyWithDebt(TEST_AMOUNT);
        uint256 gain = TEST_AMOUNT / 5;
        deal(address(asset), strategy, TEST_AMOUNT + gain);

        uint256 recipientBalanceBefore = yvUSD.balanceOf(performanceFeeRecipient);

        vm.prank(management);
        yvUSD.process_report(strategy);

        assertEq(lockedVault.feeShares(), 0, "fees should not accrue");
        assertGt(
            yvUSD.balanceOf(performanceFeeRecipient),
            recipientBalanceBefore,
            "fee recipient should get paid immediately"
        );
    }

    function test_strategyReportHarvestsWrappedVaultProfit() public {
        depositToLockedVault(alice, TEST_AMOUNT);
        uint256 totalAssetsBefore = lockedVault.totalAssets();

        address strategy = _deployMockStrategyWithDebt(TEST_AMOUNT);
        uint256 gain = TEST_AMOUNT / 10;
        deal(address(asset), strategy, TEST_AMOUNT + gain);

        vm.prank(management);
        yvUSD.process_report(strategy);

        vm.prank(management);
        (uint256 profit, uint256 loss) = lockedVault.report();

        assertEq(loss, 0, "wrapped vault should not lose here");
        assertGt(profit, 0, "strategy should realize profit");
        assertGt(lockedVault.totalAssets(), totalAssetsBefore, "total assets should increase after harvest");
    }

    function test_symbol_matchesWrappedVault() public view {
        assertEq(lockedVault.symbol(), "l-yvUSD-TEST");
    }

    function _deployMockStrategyWithDebt(uint256 debtAmount) internal returns (address) {
        Mock4626Strategy strategy = new Mock4626Strategy(asset, "Mock Strategy", "mSTRAT");

        deal(address(asset), address(yvUSD), debtAmount * 2);

        vm.startPrank(management);
        yvUSD.add_strategy(address(strategy));
        yvUSD.update_max_debt_for_strategy(address(strategy), type(uint256).max);
        yvUSD.update_debt(address(strategy), debtAmount);
        vm.stopPrank();

        if (asset.balanceOf(address(strategy)) < debtAmount) {
            deal(address(asset), address(strategy), debtAmount);
        }

        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);

        return address(strategy);
    }

    function _depositDirectlyIntoWrappedVault(address user, uint256 amount) internal returns (uint256 shares) {
        vm.startPrank(user);
        asset.approve(address(yvUSD), amount);
        shares = yvUSD.deposit(amount, user);
        vm.stopPrank();
    }
}
