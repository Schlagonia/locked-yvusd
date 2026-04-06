// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {
    IAprOracle,
    LockedVaultAprOracle
} from "../src/LockedVaultAprOracle.sol";
import {ILockedVaultAccountant} from "../src/interfaces/ILockedVaultAccountant.sol";

contract LockedVaultAprOracleTest is Test {
    uint256 internal constant MAX_BPS = 10_000;
    uint256 internal constant ONE = 1e18;

    LockedVaultAprOracle internal oracle;

    address internal lockedVault = makeAddr("lockedVault");
    address internal yearnVault = makeAddr("yearnVault");
    address internal accountant = makeAddr("accountant");

    function setUp() public {
        oracle = new LockedVaultAprOracle();

        vm.mockCall(
            lockedVault,
            abi.encodeWithSignature("vault()"),
            abi.encode(yearnVault)
        );
    }

    function test_aprAfterDebtChange_addsBaseYieldToLockerBonus() public {
        uint256 baseApr = 2_500e14;
        uint256 currentLockedAssets = 20_000e6;
        uint256 currentVaultAssets = 100_000e6;
        int256 delta = int256(10_000e6);
        uint16 lockerBonus = 1_000;

        vm.mockCall(
            address(oracle.APR_ORACLE()),
            abi.encodeWithSelector(
                IAprOracle.getStrategyApr.selector,
                yearnVault,
                0
            ),
            abi.encode(baseApr / 2)
        );
        vm.mockCall(
            address(oracle.APR_ORACLE()),
            abi.encodeWithSelector(
                IAprOracle.getStrategyApr.selector,
                yearnVault,
                delta
            ),
            abi.encode(baseApr)
        );
        vm.mockCall(
            lockedVault,
            abi.encodeWithSignature("totalAssets()"),
            abi.encode(currentLockedAssets)
        );
        vm.mockCall(
            yearnVault,
            abi.encodeWithSignature("totalAssets()"),
            abi.encode(currentVaultAssets)
        );
        vm.mockCall(
            yearnVault,
            abi.encodeWithSignature("accountant()"),
            abi.encode(accountant)
        );
        vm.mockCall(
            accountant,
            abi.encodeWithSelector(
                ILockedVaultAccountant.lockerBonus.selector,
                yearnVault
            ),
            abi.encode(lockerBonus)
        );

        uint256 postLockedAssets = uint256(int256(currentLockedAssets) + delta);
        uint256 postVaultAssets = uint256(int256(currentVaultAssets) + delta);
        uint256 lockedRatio = (postLockedAssets * ONE) / postVaultAssets;
        uint256 bonusApr = (baseApr * lockerBonus) / MAX_BPS;
        uint256 expectedApr = baseApr + (bonusApr * ONE) / lockedRatio;

        assertEq(oracle.aprAfterDebtChange(lockedVault, delta), expectedApr);
    }

    function test_aprAfterDebtChange_returnsBaseAprWithoutAccountant() public {
        uint256 baseApr = 1_500e14;
        int256 delta = int256(5_000e6);

        vm.mockCall(
            address(oracle.APR_ORACLE()),
            abi.encodeWithSelector(
                IAprOracle.getStrategyApr.selector,
                yearnVault,
                delta
            ),
            abi.encode(baseApr)
        );
        vm.mockCall(
            lockedVault,
            abi.encodeWithSignature("totalAssets()"),
            abi.encode(20_000e6)
        );
        vm.mockCall(
            yearnVault,
            abi.encodeWithSignature("totalAssets()"),
            abi.encode(100_000e6)
        );
        vm.mockCall(
            yearnVault,
            abi.encodeWithSignature("accountant()"),
            abi.encode(address(0))
        );

        assertEq(oracle.aprAfterDebtChange(lockedVault, delta), baseApr);
    }

    function test_aprAfterDebtChange_returnsBaseAprWithoutLockerBonus() public {
        uint256 baseApr = 1_500e14;
        int256 delta = int256(5_000e6);

        vm.mockCall(
            address(oracle.APR_ORACLE()),
            abi.encodeWithSelector(
                IAprOracle.getStrategyApr.selector,
                yearnVault,
                delta
            ),
            abi.encode(baseApr)
        );
        vm.mockCall(
            lockedVault,
            abi.encodeWithSignature("totalAssets()"),
            abi.encode(20_000e6)
        );
        vm.mockCall(
            yearnVault,
            abi.encodeWithSignature("totalAssets()"),
            abi.encode(100_000e6)
        );
        vm.mockCall(
            yearnVault,
            abi.encodeWithSignature("accountant()"),
            abi.encode(accountant)
        );
        vm.mockCall(
            accountant,
            abi.encodeWithSelector(
                ILockedVaultAccountant.lockerBonus.selector,
                yearnVault
            ),
            abi.encode(uint16(0))
        );

        assertEq(oracle.aprAfterDebtChange(lockedVault, delta), baseApr);
    }
}
