// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {ILockedVault} from "./interfaces/ILockedVault.sol";

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
        IERC4626 yearnVault = IERC4626(lockedVault.vault());

        uint256 baseApr = APR_ORACLE.getStrategyApr(address(yearnVault), 0);
        if (baseApr == 0) {
            return 0;
        }

        uint256 totalVaultShares = yearnVault.totalSupply();
        if (totalVaultShares == 0) {
            return 0;
        }

        int256 lockedAssets = int256(lockedVault.totalAssets()) + _delta;
        if (lockedAssets <= 0) {
            return 0;
        }

        uint256 lockedVaultShares = yearnVault.convertToShares(
            uint256(lockedAssets)
        );
        if (lockedVaultShares == 0) {
            return 0;
        }

        uint256 lockerBonusBps = lockedVault.feeConfig().lockerBonus;
        if (lockerBonusBps == 0) {
            return 0;
        }

        uint256 lockedRatio = (lockedVaultShares * ONE) / totalVaultShares;
        uint256 bonusApr = (baseApr * lockerBonusBps) / MAX_BPS;

        return (bonusApr * ONE) / lockedRatio;
    }
}
