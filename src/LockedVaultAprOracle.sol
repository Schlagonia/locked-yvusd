// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {IVault} from "@yearn-vaults/interfaces/IVault.sol";
import {ILockedVault} from "./interfaces/ILockedVault.sol";
import {ILockedVaultAccountant} from "./interfaces/ILockedVaultAccountant.sol";

interface IAprOracle {
    function getStrategyApr(
        address _strategy,
        int256 _delta
    ) external view returns (uint256);
}

contract LockedVaultAprOracle {
    uint256 internal constant MAX_BPS = 10_000;
    uint256 internal constant ONE = 1e18;

    IAprOracle public constant APR_ORACLE =
        IAprOracle(0x1981AD9F44F2EA9aDd2dC4AD7D075c102C70aF92);

    function aprAfterDebtChange(
        address _strategy,
        int256 _delta
    ) external view returns (uint256) {
        ILockedVault lockedVault = ILockedVault(_strategy);
        IVault yearnVault = IVault(lockedVault.vault());

        uint256 baseApr = APR_ORACLE.getStrategyApr(
            address(yearnVault),
            _delta
        );
        if (baseApr == 0) {
            return 0;
        }

        int256 totalVaultAssets = int256(yearnVault.totalAssets()) + _delta;
        if (totalVaultAssets <= 0) {
            return 0;
        }

        int256 lockedAssets = int256(lockedVault.totalAssets()) + _delta;
        if (lockedAssets <= 0) {
            return 0;
        }

        address accountant = yearnVault.accountant();
        if (accountant == address(0)) {
            return baseApr;
        }

        uint256 lockerBonus = ILockedVaultAccountant(accountant).lockerBonus(
            address(yearnVault)
        );
        if (lockerBonus == 0) {
            return baseApr;
        }

        uint256 lockedRatio = (uint256(lockedAssets) * ONE) /
            uint256(totalVaultAssets);
        uint256 bonusApr = (baseApr * lockerBonus) / MAX_BPS;

        return baseApr + (bonusApr * ONE) / lockedRatio;
    }
}
