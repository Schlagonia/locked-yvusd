// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {ILockedyvUSD} from "./interfaces/ILockedyvUSD.sol";

interface IAprOracle {
    function getStrategyApr(
        address _strategy,
        int256 _delta
    ) external view returns (uint256);
}

/// @notice APR oracle for LockedyvUSD that returns only the locker bonus APR.
contract LockedyvUSDAprOracle {
    uint256 internal constant MAX_BPS = 10_000;
    uint256 internal constant ONE = 1e18;

    IAprOracle public constant aprOracle =
        IAprOracle(0x1981AD9F44F2EA9aDd2dC4AD7D075c102C70aF92);

    function aprAfterDebtChange(
        address _strategy,
        int256 _delta
    ) external view returns (uint256) {
        IERC4626 yvUSDVault = IERC4626(IERC4626(_strategy).asset());

        uint256 baseApr = aprOracle.getStrategyApr(address(yvUSDVault), 0);
        if (baseApr == 0) return 0;

        uint256 totalYvUsdShares = yvUSDVault.totalSupply();

        uint256 lockedShares = uint256(
            int256(IERC4626(_strategy).totalAssets()) + _delta
        );
        if (lockedShares == 0) return 0;

        uint256 lockerBonusBps = ILockedyvUSD(_strategy)
            .feeConfig()
            .lockerBonus;
        if (lockerBonusBps == 0) return 0;

        uint256 lockedRatio = (lockedShares * ONE) / totalYvUsdShares;

        uint256 bonusApr = (baseApr * lockerBonusBps) / MAX_BPS;
        bonusApr = (bonusApr * ONE) / lockedRatio;

        return bonusApr;
    }
}
