// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {IBaseHealthCheck} from "@periphery/Bases/HealthCheck/IBaseHealthCheck.sol";
/**
 * @notice Interface for the LockedyvUSD contract
 * @dev Provides access to the LockedyvUSD contract's functions
 */
interface ILockedyvUSD is IBaseHealthCheck {
     event CooldownDurationUpdated(uint256 indexed newCooldownDuration);
    event WithdrawalWindowUpdated(uint256 indexed newWithdrawalWindow);
    event CooldownStarted(
        address indexed user,
        uint256 indexed shares,
        uint256 indexed timestamp
    );
    event CooldownCancelled(address indexed user);
    event FeesUpdated(
        uint256 indexed managementFee,
        uint256 indexed performanceFee,
        uint256 indexed lockerBonus
    );
    event FeesReported(
        uint256 indexed managementFee,
        uint256 indexed performanceFee,
        uint256 indexed lockerBonus
    );

    /// @notice Tracks user cooldown state (packed into single storage slot)
    struct UserCooldown {
        uint64 cooldownEnd; // When cooldown expires (8 bytes)
        uint64 windowEnd; // When withdrawal window closes (8 bytes)
        uint128 shares; // Shares locked for withdrawal (16 bytes)
    }

    /// @notice Fee configuration for a vault
    struct FeeConfig {
        uint16 managementFee; // Annual management fee in basis points
        uint16 performanceFee; // Performance fee on gains in basis points
        uint16 lockerBonus; // Locked vault fee in basis points
    }

    /// @notice Immutable reference to the vault factory
    function VAULT_FACTORY() external view returns (address);

    /// @notice Accumulated fee shares awaiting withdrawal
    function feeShares() external view returns (uint256);

    /// @notice Current fee configuration
    function feeConfig() external view returns (FeeConfig memory);

    /// @notice Duration users must wait before withdrawing (default: 14 days)
    function cooldownDuration() external view returns (uint256);

    /// @notice Window after cooldown during which users can withdraw (default: 7 days)
    function withdrawalWindow() external view returns (uint256);

    /// @notice Mapping of user addresses to their cooldown status
    function cooldowns(address _user) external view returns (UserCooldown memory);

    /// @notice Starts the cooldown for a user
    function startCooldown(address _user, uint256 _shares) external;

    /// @notice Cancels the cooldown for a user
    function cancelCooldown(address _user) external;

    function getCooldownStatus(address _user) external view returns (uint256 cooldownEnd, uint256 windowEnd, uint256 shares);

    function withdrawFees() external;

    /// @notice Withdraws the fees for a user
    function withdrawFees(address _receiver) external;

    /// @notice Sets the cooldown duration
    function setCooldownDuration(uint256 _cooldownDuration) external;

    /// @notice Sets the withdrawal window
    function setWithdrawalWindow(uint256 _withdrawalWindow) external;

    /// @notice Sets the fee configuration
    function setFees(uint16 _managementFee, uint16 _performanceFee, uint16 _lockerBonus) external;

    /// @notice Reports the gain and loss of the strategy
    function report(address _strategy, uint256 _gain, uint256 _loss) external returns (uint256 _fees, uint256 _refunds);
    
}