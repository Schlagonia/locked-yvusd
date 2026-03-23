// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {LockerZapper} from "../src/LockerZapper.sol";
import {Mock4626Strategy} from "./mocks/Mock4626Strategy.sol";
import {MockLockedVault} from "./mocks/MockLockedVault.sol";
import {Token} from "@yearn-vaults/test/Token.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

contract LockerZapperLocalTest is Test {
    Token public usdc;
    Mock4626Strategy public vault;
    MockLockedVault public lockedVault;
    LockerZapper public zapper;

    address public alice;
    address public bob;

    uint256 internal constant INITIAL_DEPOSIT = 1_000_000e6;
    uint256 internal constant TEST_AMOUNT = 10_000e6;

    function setUp() public {
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        usdc = new Token("USDC", 6);
        vault = new Mock4626Strategy(IERC20(address(usdc)), "yvUSD Local Vault", "yvUSD-LOCAL");
        lockedVault = new MockLockedVault(IERC20(address(vault)), "Locked yvUSD", "lyvUSD");
        zapper = new LockerZapper(address(lockedVault));

        usdc.mint(alice, INITIAL_DEPOSIT);
        usdc.mint(bob, INITIAL_DEPOSIT);
    }

    function test_zapOut_maxShares_usesMaxWithdrawToAvoidDust() public {
        vm.startPrank(alice);
        usdc.approve(address(zapper), TEST_AMOUNT);
        uint256 aliceShares = zapper.zapIn(TEST_AMOUNT);
        vm.stopPrank();

        vm.startPrank(bob);
        usdc.approve(address(zapper), TEST_AMOUNT);
        zapper.zapIn(TEST_AMOUNT);
        vm.stopPrank();

        usdc.mint(address(this), 1);
        usdc.approve(address(vault), 1);
        uint256 donatedVaultShares = vault.deposit(1, address(this));
        IERC20(address(vault)).transfer(address(lockedVault), donatedVaultShares);

        vm.startPrank(alice);
        lockedVault.startCooldown(aliceShares);

        uint256 maxWithdrawAssets = IERC4626(address(lockedVault)).maxWithdraw(alice);
        uint256 maxRedeemShares = IERC4626(address(lockedVault)).maxRedeem(alice);

        assertEq(maxWithdrawAssets, TEST_AMOUNT, "maxWithdraw should preserve the full asset exit");
        assertEq(maxRedeemShares, aliceShares - 1, "maxRedeem rounds down and leaves dust");

        IERC20(address(lockedVault)).approve(address(zapper), type(uint256).max);

        uint256 assetsReceived = zapper.zapOut(type(uint256).max);
        vm.stopPrank();

        assertEq(assetsReceived, TEST_AMOUNT, "Should withdraw the full asset amount");
        assertEq(IERC20(address(lockedVault)).balanceOf(alice), 0, "Should burn all locked shares");
    }

    function test_zapper_canBeReusedForYvBTCStyleVault() public {
        Token wbtc = new Token("WBTC", 8);
        Mock4626Strategy yvBTC = new Mock4626Strategy(IERC20(address(wbtc)), "yvBTC Local Vault", "yvBTC-LOCAL");
        MockLockedVault lockedYvBTC = new MockLockedVault(IERC20(address(yvBTC)), "Locked yvBTC", "lyvBTC");
        LockerZapper btcZapper = new LockerZapper(address(lockedYvBTC));
        address satoshi = makeAddr("satoshi");
        uint256 depositAmount = 1e8;

        wbtc.mint(satoshi, depositAmount);

        vm.startPrank(satoshi);
        IERC20(address(wbtc)).approve(address(btcZapper), depositAmount);

        uint256 lockedShares = btcZapper.zapIn(depositAmount);
        lockedYvBTC.startCooldown(lockedShares);

        IERC20(address(lockedYvBTC)).approve(address(btcZapper), type(uint256).max);

        uint256 assetsReceived = btcZapper.zapOut(type(uint256).max);
        vm.stopPrank();

        assertEq(assetsReceived, depositAmount, "Should round-trip the BTC-style vault");
        assertEq(IERC20(address(lockedYvBTC)).balanceOf(satoshi), 0, "Should clear locked shares");
        assertEq(wbtc.balanceOf(satoshi), depositAmount, "Should return the base asset");
    }
}
