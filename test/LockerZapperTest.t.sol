// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IVault} from "@yearn-vaults/interfaces/IVault.sol";
import {IVaultFactory} from "@yearn-vaults/interfaces/IVaultFactory.sol";
import {Roles} from "@yearn-vaults/interfaces/Roles.sol";

import {LockedVault} from "../src/LockedVault.sol";
import {LockedVaultAccountant} from "../src/LockedVaultAccountant.sol";
import {LockerZapper} from "../src/LockerZapper.sol";
import {ILockedVault} from "../src/interfaces/ILockedVault.sol";
import {MockIlliquid4626Strategy} from "./mocks/MockIlliquid4626Strategy.sol";

contract LockerZapperTest is Test {
    ILockedVault public lockedVault;
    LockedVaultAccountant public accountant;
    LockerZapper public zapper;
    IVault public yvUSD;
    IVaultFactory public vaultFactory;
    IERC20 public asset;

    address constant VAULT_FACTORY = 0x770D0d1Fb036483Ed4AbB6d53c1C88fb277D812F;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant GOVERNANCE = 0x88Ba032be87d5EF1fbE87336B7090767F367BF73;

    address public management;
    address public performanceFeeRecipient;
    address public alice;
    address public bob;

    uint256 constant COOLDOWN_DURATION = 14 days;
    uint256 constant TEST_AMOUNT = 10_000e6;
    uint256 constant INITIAL_DEPOSIT = 1_000_000e6;
    uint256 constant ILLIQUID_DEBT = 9_000e6;

    event ZappedOut(
        address indexed lockedVault,
        address indexed owner,
        address indexed receiver,
        uint256 lockedShares,
        uint256 unlockedSharesOut
    );
    event ZappedIn(
        address indexed lockedVault,
        address indexed owner,
        address indexed receiver,
        uint256 unlockedSharesIn,
        uint256 lockedSharesOut
    );

    function setUp() public {
        management = makeAddr("management");
        performanceFeeRecipient = makeAddr("performanceFeeRecipient");
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        vaultFactory = IVaultFactory(VAULT_FACTORY);
        asset = IERC20(USDC);

        vm.startPrank(management);
        yvUSD = IVault(
            vaultFactory.deploy_new_vault(
                address(asset),
                "yvUSD Test Vault",
                "yvUSD-TEST",
                management,
                7 days
            )
        );

        lockedVault = ILockedVault(
            address(new LockedVault(address(yvUSD), "Locked Vault"))
        );
        accountant = new LockedVaultAccountant(GOVERNANCE);
        zapper = new LockerZapper();

        lockedVault.setPerformanceFee(0);
        lockedVault.setPerformanceFeeRecipient(performanceFeeRecipient);
        lockedVault.setProfitMaxUnlockTime(7 days);
        lockedVault.setDoHealthCheck(false);
        lockedVault.setProfitLimitRatio(10_000);
        lockedVault.setLossLimitRatio(500);

        yvUSD.set_role(management, Roles.ALL);
        yvUSD.set_deposit_limit(type(uint256).max);
        vm.stopPrank();

        vm.prank(GOVERNANCE);
        accountant.setVaultConfig(
            address(yvUSD),
            address(lockedVault),
            25,
            1_000,
            1_000,
            0
        );

        vm.prank(management);
        yvUSD.set_accountant(address(accountant));

        deal(address(asset), alice, INITIAL_DEPOSIT);
        deal(address(asset), bob, INITIAL_DEPOSIT);
    }

    function test_zapOut_returnsUnlockedShares() public {
        uint256 shares = _depositToLockedVault(alice, TEST_AMOUNT);
        _startCooldownAndApprove(alice, shares);

        uint256 expectedAssetsOut = lockedVault.previewRedeem(shares);
        uint256 expectedSharesOut = yvUSD.previewDeposit(expectedAssetsOut);

        vm.expectEmit(true, true, true, true);
        emit ZappedOut(
            address(lockedVault),
            alice,
            bob,
            shares,
            expectedSharesOut
        );

        vm.prank(alice);
        uint256 unlockedSharesOut = zapper.zapOut(
            address(lockedVault),
            shares,
            bob,
            expectedSharesOut
        );

        assertEq(unlockedSharesOut, expectedSharesOut, "output should match deposit preview");
        assertEq(lockedVault.balanceOf(alice), 0, "locked shares should be burned");
        assertEq(
            IERC20(address(yvUSD)).balanceOf(bob),
            unlockedSharesOut,
            "receiver should get unlocked vault shares"
        );
        assertEq(
            IERC20(address(yvUSD)).balanceOf(address(zapper)),
            0,
            "zapper should not retain unlocked shares"
        );
        assertEq(asset.balanceOf(address(zapper)), 0, "zapper should not retain asset dust");
    }

    function test_zapIn_returnsLockedShares() public {
        uint256 shares = _depositToUnlockedVault(alice, TEST_AMOUNT);
        _approveUnlockedVaultShares(alice, shares);

        uint256 expectedAssetsOut = yvUSD.previewRedeem(shares);
        uint256 expectedLockedSharesOut = lockedVault.previewDeposit(
            expectedAssetsOut
        );

        vm.expectEmit(true, true, true, true);
        emit ZappedIn(
            address(lockedVault),
            alice,
            bob,
            shares,
            expectedLockedSharesOut
        );

        vm.prank(alice);
        uint256 lockedSharesOut = zapper.zapIn(
            address(lockedVault),
            shares,
            bob,
            expectedLockedSharesOut
        );

        assertEq(
            lockedSharesOut,
            expectedLockedSharesOut,
            "output should match deposit preview"
        );
        assertEq(
            IERC20(address(yvUSD)).balanceOf(alice),
            0,
            "unlocked shares should be burned"
        );
        assertEq(
            lockedVault.balanceOf(bob),
            lockedSharesOut,
            "receiver should get locked shares"
        );
        assertEq(
            lockedVault.balanceOf(address(zapper)),
            0,
            "zapper should not retain locked shares"
        );
        assertEq(
            IERC20(address(yvUSD)).balanceOf(address(zapper)),
            0,
            "zapper should not retain unlocked shares"
        );
        assertEq(
            asset.balanceOf(address(zapper)),
            0,
            "zapper should not retain asset dust"
        );
    }

    function test_zapOut_worksWhenVaultIsIlliquid() public {
        uint256 shares = _depositToLockedVault(alice, TEST_AMOUNT);
        _makeVaultIlliquid(ILLIQUID_DEBT);
        _startCooldownAndApprove(alice, shares);

        uint256 expectedAssetsOut = lockedVault.previewRedeem(shares);
        uint256 expectedSharesOut = yvUSD.previewDeposit(expectedAssetsOut);

        vm.prank(alice);
        vm.expectRevert("ERC4626: redeem more than max");
        lockedVault.redeem(shares, alice, alice);

        vm.prank(alice);
        uint256 unlockedSharesOut = zapper.zapOut(
            address(lockedVault),
            shares,
            bob,
            expectedSharesOut
        );

        assertEq(
            unlockedSharesOut,
            expectedSharesOut,
            "illiquid exit should still mint the expected unlocked shares"
        );
        assertEq(lockedVault.balanceOf(alice), 0, "locked shares should be burned");
        assertEq(
            IERC20(address(yvUSD)).balanceOf(bob),
            unlockedSharesOut,
            "receiver should get unlocked shares after the flash unwind"
        );
        assertEq(
            IERC20(address(yvUSD)).balanceOf(address(zapper)),
            0,
            "zapper should not retain unlocked shares"
        );
        assertEq(asset.balanceOf(address(zapper)), 0, "zapper should not retain asset dust");
    }

    function test_zapIn_worksWhenVaultIsIlliquid() public {
        uint256 shares = _depositToUnlockedVault(alice, TEST_AMOUNT);
        _makeVaultIlliquid(ILLIQUID_DEBT);
        _approveUnlockedVaultShares(alice, shares);

        uint256 expectedAssetsOut = yvUSD.previewRedeem(shares);
        uint256 expectedLockedSharesOut = lockedVault.previewDeposit(
            expectedAssetsOut
        );

        vm.prank(alice);
        vm.expectRevert();
        yvUSD.redeem(shares, alice, alice);

        vm.prank(alice);
        uint256 lockedSharesOut = zapper.zapIn(
            address(lockedVault),
            shares,
            bob,
            expectedLockedSharesOut
        );

        assertEq(
            lockedSharesOut,
            expectedLockedSharesOut,
            "illiquid entry should still mint the expected locked shares"
        );
        assertEq(
            IERC20(address(yvUSD)).balanceOf(alice),
            0,
            "unlocked shares should be burned"
        );
        assertEq(
            lockedVault.balanceOf(bob),
            lockedSharesOut,
            "receiver should get locked shares after the flash loop"
        );
        assertEq(
            lockedVault.balanceOf(address(zapper)),
            0,
            "zapper should not retain locked shares"
        );
        assertEq(
            IERC20(address(yvUSD)).balanceOf(address(zapper)),
            0,
            "zapper should not retain unlocked shares"
        );
        assertEq(
            asset.balanceOf(address(zapper)),
            0,
            "zapper should not retain asset dust"
        );
    }

    function test_zapOut_zeroShares_stillReverts() public {
        vm.prank(alice);
        vm.expectRevert();
        zapper.zapOut(address(lockedVault), 0, bob, 0);
    }

    function test_zapOut_zeroReceiver_stillReverts() public {
        uint256 shares = _depositToLockedVault(alice, TEST_AMOUNT);
        _startCooldownAndApprove(alice, shares);

        vm.prank(alice);
        vm.expectRevert();
        zapper.zapOut(address(lockedVault), 1, address(0), 0);
    }

    function test_zapOut_zeroLockedVault_stillReverts() public {
        vm.expectRevert();
        zapper.zapOut(address(0), 1, bob, 0);
    }

    function test_zapOut_revertsWithoutApproval() public {
        uint256 shares = _depositToLockedVault(alice, TEST_AMOUNT);
        _startCooldown(alice, shares);

        vm.prank(alice);
        vm.expectRevert();
        zapper.zapOut(address(lockedVault), shares, bob, 0);
    }

    function test_zapIn_revertsWithoutApproval() public {
        uint256 shares = _depositToUnlockedVault(alice, TEST_AMOUNT);

        vm.prank(alice);
        vm.expectRevert();
        zapper.zapIn(address(lockedVault), shares, bob, 0);
    }

    function test_zapOut_revertsWhenMinUnlockedSharesIsTooHigh() public {
        uint256 shares = _depositToLockedVault(alice, TEST_AMOUNT);
        _startCooldownAndApprove(alice, shares);
        uint256 expectedAssetsOut = lockedVault.previewRedeem(shares);
        uint256 expectedSharesOut = yvUSD.previewDeposit(expectedAssetsOut);

        vm.prank(alice);
        vm.expectRevert("!min out");
        zapper.zapOut(address(lockedVault), shares, bob, expectedSharesOut + 1);
    }

    function test_zapIn_revertsWhenMinLockedSharesIsTooHigh() public {
        uint256 shares = _depositToUnlockedVault(alice, TEST_AMOUNT);
        _approveUnlockedVaultShares(alice, shares);
        uint256 expectedAssetsOut = yvUSD.previewRedeem(shares);
        uint256 expectedLockedSharesOut = lockedVault.previewDeposit(
            expectedAssetsOut
        );

        vm.prank(alice);
        vm.expectRevert("!min out");
        zapper.zapIn(
            address(lockedVault),
            shares,
            bob,
            expectedLockedSharesOut + 1
        );
    }

    function test_onMorphoFlashLoan_revertsIfNotMorpho() public {
        vm.expectRevert("Not Morpho");
        zapper.onMorphoFlashLoan(1, bytes(""));
    }

    function _depositToLockedVault(
        address user,
        uint256 amount
    ) internal returns (uint256 shares) {
        vm.startPrank(user);
        asset.approve(address(lockedVault), amount);
        shares = lockedVault.deposit(amount, user);
        vm.stopPrank();
    }

    function _depositToUnlockedVault(
        address user,
        uint256 amount
    ) internal returns (uint256 shares) {
        vm.startPrank(user);
        asset.approve(address(yvUSD), amount);
        shares = yvUSD.deposit(amount, user);
        vm.stopPrank();
    }

    function _startCooldownAndApprove(address user, uint256 shares) internal {
        _startCooldown(user, shares);

        vm.prank(user);
        lockedVault.approve(address(zapper), shares);
    }

    function _approveUnlockedVaultShares(address user, uint256 shares) internal {
        vm.prank(user);
        IERC20(address(yvUSD)).approve(address(zapper), shares);
    }

    function _startCooldown(address user, uint256 shares) internal {
        vm.prank(user);
        lockedVault.startCooldown(shares);

        vm.warp(block.timestamp + COOLDOWN_DURATION + 1 days);
    }

    function _makeVaultIlliquid(uint256 debtAmount) internal {
        MockIlliquid4626Strategy strategy = new MockIlliquid4626Strategy(
            asset,
            "Illiquid Strategy",
            "illUSD"
        );

        vm.startPrank(management);
        yvUSD.add_strategy(address(strategy));
        yvUSD.update_max_debt_for_strategy(address(strategy), type(uint256).max);
        yvUSD.update_debt(address(strategy), debtAmount);
        vm.stopPrank();
    }
}
