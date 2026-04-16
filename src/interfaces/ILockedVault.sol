// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {IBase4626Compounder} from "@periphery/Bases/4626Compounder/IBase4626Compounder.sol";

interface ILockedVault is IBase4626Compounder {
    event CooldownDurationUpdated(uint256 indexed newCooldownDuration);
    event WithdrawalWindowUpdated(uint256 indexed newWithdrawalWindow);
    event CooldownStarted(
        address indexed user,
        uint256 indexed shares,
        uint256 indexed timestamp
    );
    event CooldownCancelled(address indexed user);

    struct UserCooldown {
        uint64 cooldownEnd;
        uint64 windowEnd;
        uint128 shares;
    }

    function GOVERNANCE() external view returns (address);

    function MAX_COOLDOWN_DURATION() external view returns (uint256);

    function cooldownDuration() external view returns (uint256);

    function withdrawalWindow() external view returns (uint256);

    function cooldowns(
        address _user
    ) external view returns (UserCooldown memory);

    function startCooldown(uint256 _shares) external;

    function cancelCooldown() external;

    function getCooldownStatus(
        address _user
    )
        external
        view
        returns (uint256 cooldownEnd, uint256 windowEnd, uint256 shares);

    function setCooldownDuration(uint256 _cooldownDuration) external;

    function setWithdrawalWindow(uint256 _withdrawalWindow) external;
}
