// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {BaseHooks, ERC20} from "@periphery/Bases/Hooks/BaseHooks.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IVault} from "@yearn-vaults/interfaces/IVault.sol";
import {IVaultFactory} from "@yearn-vaults/interfaces/IVaultFactory.sol";

/**
 * @notice Interface extension for vault factory access
 * @dev Provides access to the vault's factory address
 */
interface IVaultCorrected {
    /**
     * @notice Returns the factory address that deployed this vault
     * @return The factory contract address
     */
    function FACTORY() external view returns (address);
}

/**
 * @title LockedyvUSD
 * @author Yearn Finance
 * @notice A vault hook contract that implements cooldown periods for withdrawals
 * @dev This contract extends BaseHooks to add withdrawal restrictions through a cooldown mechanism.
 *      Users must initiate a cooldown period before they can withdraw their funds, and then must
 *      withdraw within a specified window after the cooldown expires.
 */
contract LockedyvUSD is BaseHooks {
    using SafeERC20 for ERC20;

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

    /// @notice Maximum allowed management fee (2% annually)
    uint256 internal constant MAX_MANAGEMENT_FEE = 200;

    /// @notice Seconds in a year for fee calculations
    uint256 internal constant SECS_PER_YEAR = 31_556_952;

    /// @notice Immutable reference to the vault factory
    IVaultFactory public immutable VAULT_FACTORY;

    /// @notice Accumulated fee shares awaiting withdrawal
    uint256 public feeShares;

    /// @notice Current fee configuration
    FeeConfig public feeConfig;

    /// @notice Duration users must wait before withdrawing (default: 14 days)
    uint256 public cooldownDuration;

    /// @notice Window after cooldown during which users can withdraw (default: 7 days)
    uint256 public withdrawalWindow;

    /// @notice Mapping of user addresses to their cooldown status
    mapping(address => UserCooldown) public cooldowns;

    /**
     * @notice Initializes the LockedyvUSD contract
     * @param _asset The vault (yvUSD) that this contract will hook into
     * @param _name The name for the locked token
     */
    constructor(address _asset, string memory _name) BaseHooks(_asset, _name) {
        VAULT_FACTORY = IVaultFactory(IVaultCorrected(_asset).FACTORY());

        cooldownDuration = 14 days;
        withdrawalWindow = 7 days;
        emit CooldownDurationUpdated(cooldownDuration);
        emit WithdrawalWindowUpdated(withdrawalWindow);
    }

    /**
     * @notice Processes strategy reports and calculates fees
     * @dev Called by the vault when a strategy reports gains/losses.
     *      Calculates management, performance, and locked vault fees based on the gain.
     *      Management fees are charged based on time elapsed and debt amount.
     *      Performance and locked vault fees are only charged on gains.
     * @param _strategy The strategy address reporting
     * @param _gain Amount of gain reported by the strategy
     * @param _loss Amount of loss reported by the strategy (unused but required by interface)
     * @return _fees Total fees to be charged in asset tokens
     * @return _refunds Always returns 0 (no refunds in this implementation)
     */
    function report(
        address _strategy,
        uint256 _gain,
        uint256 _loss
    ) external returns (uint256 _fees, uint256 _refunds) {
        require(msg.sender == address(asset), "only vault");

        FeeConfig memory fee = feeConfig;

        // Retrieve the strategy's params from the vault.
        IVault.StrategyParams memory strategyParams = IVault(msg.sender)
            .strategies(_strategy);

        require(
            strategyParams.last_report != block.timestamp,
            "already reported"
        );

        _vaultHealthCheck(strategyParams.current_debt, _gain, _loss);

        // Charge management fees no matter gain or loss.
        uint256 managementFee;
        uint256 performanceFee;
        uint256 lockerBonus;

        // Only charge performance fees if there is a gain.
        if (_gain > 0) {
            if (fee.managementFee > 0) {
                // Time since the last harvest.
                uint256 duration = block.timestamp - strategyParams.last_report;
                // managementFee is an annual amount, so charge based on the time passed.
                managementFee = ((strategyParams.current_debt *
                    duration *
                    (fee.managementFee)) /
                    MAX_BPS /
                    SECS_PER_YEAR);
            }

            performanceFee = (_gain * (fee.performanceFee)) / MAX_BPS;

            lockerBonus = (_gain * (fee.lockerBonus)) / MAX_BPS;
        } else {
            return (0, 0);
        }

        _fees = managementFee + performanceFee + lockerBonus;

        if (_fees > _gain) {
            _fees = _gain;
            managementFee = _gain - (performanceFee + lockerBonus);
        }

        if (_fees == 0) {
            return (0, 0);
        }

        // Get the expected fee shares based on the fees reported.
        uint256 expectedFeeShares = getExpectedShares(_fees) *
            ((performanceFee + managementFee) / _fees);

        if (asset.balanceOf(address(this)) >= expectedFeeShares) {
            // If the balance of the vault is greater than the expected fee shares, transfer the fee shares to the performance fee recipient.
            asset.safeTransfer(
                TokenizedStrategy.performanceFeeRecipient(),
                expectedFeeShares
            );
        } else {
            // If the balance of the vault is less than the expected fee shares, add to the fee shares to pay later.
            feeShares += expectedFeeShares;
        }

        emit FeesReported(managementFee, performanceFee, lockerBonus);
    }

    /**
     * @notice Performs a health check on the vault using BaseHealthCheck parameters.
     * @dev Checks if the gain or loss is within the acceptable bounds.
     * @param _currentDebt The current debt of the strategy
     * @param _gain The gain reported by the strategy
     * @param _loss The loss reported by the strategy
     */
    function _vaultHealthCheck(
        uint256 _currentDebt,
        uint256 _gain,
        uint256 _loss
    ) internal {
        if (!doHealthCheck) {
            doHealthCheck = true;
            return;
        }

        if (_gain > 0) {
            require(
                (_gain <= (_currentDebt * profitLimitRatio()) / MAX_BPS),
                "healthCheck"
            );
        } else if (_loss > 0) {
            require(
                (_loss <= ((_currentDebt * lossLimitRatio()) / MAX_BPS)),
                "healthCheck"
            );
        }
    }

    /**
     * @notice Calculates expected shares after protocol fee deduction
     * @dev Computes the net shares that will be received after the vault factory
     *      takes its protocol fee cut. Used during fee reporting to accurately
     *      track fee shares.
     * @param _fees The fee amount in asset tokens
     * @return The net shares after protocol fee deduction
     */
    function getExpectedShares(uint256 _fees) public view returns (uint256) {
        if (_fees == 0) return 0;

        uint256 totalShares = IVault(msg.sender).convertToShares(_fees);
        (uint16 protocolFee, ) = VAULT_FACTORY.protocol_fee_config(
            address(asset)
        );

        if (protocolFee > 0) {
            uint256 protocolShares = (totalShares * protocolFee) / MAX_BPS;
            totalShares -= protocolShares;
        }

        return totalShares;
    }

    /**
     * @notice Deploy funds to strategies (no-op for this implementation)
     * @dev Override from BaseHooks. This hook doesn't deploy funds elsewhere.
     * @param _amount Amount to deploy (unused)
     */
    function _deployFunds(uint256 _amount) internal override {}

    /**
     * @notice Free funds from strategies (no-op for this implementation)
     * @dev Override from BaseHooks. This hook doesn't need to free funds.
     * @param _amount Amount to free (unused)
     */
    function _freeFunds(uint256 _amount) internal override {}

    /**
     * @notice Report available balance for harvest
     * @dev Override from BaseHooks. Returns vault token balance minus accumulated fee shares.
     * @return Available balance that can be harvested
     */
    function _harvestAndReport() internal override returns (uint256) {
        return asset.balanceOf(address(this)) - feeShares;
    }

    /**
     * @notice Post-withdraw hook to update cooldown after successful withdrawal
     * @dev Override from BaseHooks. Updates or clears the user's cooldown state
     *      after a successful withdrawal. If withdrawing all cooldown shares,
     *      the cooldown is cleared. For partial withdrawals, cooldown shares are reduced.
     * @param assets Amount of assets withdrawn (unused but required by interface)
     * @param shares Amount of shares withdrawn
     * @param receiver Address receiving the assets (unused but required by interface)
     * @param owner Address that owns the shares being withdrawn
     * @param maxLoss Maximum loss tolerance (unused but required by interface)
     */
    function _postWithdrawHook(
        uint256 assets,
        uint256 shares,
        address receiver,
        address owner,
        uint256 maxLoss
    ) internal override {
        // Update cooldown after successful withdrawal
        UserCooldown storage cooldown = cooldowns[owner];
        if (cooldown.shares > 0) {
            if (shares >= cooldown.shares) {
                // Full withdrawal - clear the cooldown
                delete cooldowns[owner];
            } else {
                // Partial withdrawal - reduce cooldown shares
                cooldown.shares -= uint128(shares);
            }
        }
    }

    /**
     * @notice Prevent transfers during lock period or active cooldown
     * @dev Override from BaseHooksUpgradeable to enforce lock and cooldown
     * @param from Address transferring shares
     * @param to Address receiving shares
     * @param amount Amount of shares being transferred
     */
    function _preTransferHook(
        address from,
        address to,
        uint256 amount
    ) internal override {
        // Allow minting (from == 0) and burning (to == 0)
        if (from == address(0) || to == address(0)) return;

        // Check if user has active cooldown
        UserCooldown memory cooldown = cooldowns[from];
        if (cooldown.shares > 0) {
            // User has shares in cooldown, check if trying to transfer them
            uint256 userBalance = TokenizedStrategy.balanceOf(from);
            uint256 nonCooldownShares = userBalance > cooldown.shares
                ? userBalance - cooldown.shares
                : 0;

            // Only allow transfer of non-cooldown shares
            require(
                amount <= nonCooldownShares,
                "Cannot transfer shares in cooldown"
            );
        }
    }

    /**
     * @notice Start cooldown for withdrawal
     * @param shares Number of shares to cooldown for withdrawal
     */
    function startCooldown(uint256 shares) external {
        require(shares > 0, "Invalid shares");

        // Validate shares against actual balance
        uint256 userBalance = TokenizedStrategy.balanceOf(msg.sender);
        require(shares <= userBalance, "Insufficient balance for cooldown");

        // Read cooldown duration from ProtocolConfig
        uint256 cooldownPeriod = cooldownDuration;

        // Allow updating cooldown with new amount (overwrites previous)
        cooldowns[msg.sender] = UserCooldown({
            cooldownEnd: uint64(block.timestamp + cooldownPeriod),
            windowEnd: uint64(
                block.timestamp + cooldownPeriod + withdrawalWindow
            ),
            shares: uint128(shares)
        });

        emit CooldownStarted(msg.sender, shares, block.timestamp);
    }

    /**
     * @notice Cancel active cooldown
     * @dev Resets cooldown state, requiring user to start new cooldown to withdraw
     */
    function cancelCooldown() external {
        require(cooldowns[msg.sender].shares > 0, "No active cooldown");
        delete cooldowns[msg.sender];
        emit CooldownCancelled(msg.sender);
    }

    /**
     * @notice Returns the maximum amount a user can withdraw
     * @dev Enforces lock period, cooldown, and withdrawal window requirements.
     *      Returns 0 if user hasn't started cooldown, is still in cooldown period,
     *      or the withdrawal window has expired. During shutdown or when cooldown
     *      is disabled (duration = 0), returns max uint to allow unrestricted withdrawals.
     * @param _owner Address to check withdrawal limit for
     * @return Maximum withdrawal amount allowed in assets
     */
    function availableWithdrawLimit(
        address _owner
    ) public view override returns (uint256) {
        // If cooldown is off or during shutdown, bypass all checks and return available assets
        if (cooldownDuration == 0 || TokenizedStrategy.isShutdown()) {
            // Return all available vault shares
            return type(uint256).max;
        }

        UserCooldown memory cooldown = cooldowns[_owner];

        // No cooldown started - cannot withdraw
        if (cooldown.shares == 0) {
            return 0;
        }

        // Still in cooldown period
        if (block.timestamp < cooldown.cooldownEnd) {
            return 0;
        }

        // Window expired - must restart cooldown
        if (block.timestamp > cooldown.windowEnd) {
            return 0;
        }

        // Within valid withdrawal window - check backing requirement
        return TokenizedStrategy.convertToAssets(cooldown.shares);
    }

    /**
     * @notice Get user's cooldown status
     * @param user Address to check
     * @return cooldownEnd When cooldown expires (0 if no cooldown)
     * @return windowEnd When withdrawal window closes
     * @return shares Number of shares in cooldown
     */
    function getCooldownStatus(
        address user
    )
        external
        view
        returns (uint256 cooldownEnd, uint256 windowEnd, uint256 shares)
    {
        UserCooldown memory cooldown = cooldowns[user];
        return (cooldown.cooldownEnd, cooldown.windowEnd, cooldown.shares);
    }

    /**
     * @notice Update the cooldown duration
     * @dev Only callable by management. Setting to 0 disables cooldown requirements.
     * @param _cooldownDuration New cooldown duration in seconds
     */
    function setCooldownDuration(
        uint256 _cooldownDuration
    ) external onlyManagement {
        cooldownDuration = _cooldownDuration;
        emit CooldownDurationUpdated(cooldownDuration);
    }

    /**
     * @notice Update the withdrawal window duration
     * @dev Only callable by management. Must be at least 1 day for safety.
     *      This is the period after cooldown expires during which users can withdraw.
     * @param _withdrawalWindow New withdrawal window duration in seconds
     */
    function setWithdrawalWindow(
        uint256 _withdrawalWindow
    ) external onlyManagement {
        require(_withdrawalWindow > 1 days, "Withdrawal window too short");
        withdrawalWindow = _withdrawalWindow;
        emit WithdrawalWindowUpdated(withdrawalWindow);
    }

    /**
     * @notice Update fee configuration for a vault
     * @param _managementFee New annual management fee in basis points
     * @param _performanceFee New performance fee on gains in basis points
     * @param _lockerBonus New locked vault fee in basis points
     */
    function setFees(
        uint16 _managementFee,
        uint16 _performanceFee,
        uint16 _lockerBonus
    ) external onlyManagement {
        require(
            _managementFee <= MAX_MANAGEMENT_FEE,
            "Management fee too high"
        );
        require(_performanceFee + _lockerBonus <= MAX_BPS, "Total too high");

        feeConfig = FeeConfig({
            managementFee: _managementFee,
            performanceFee: _performanceFee,
            lockerBonus: _lockerBonus
        });

        emit FeesUpdated(_managementFee, _performanceFee, _lockerBonus);
    }

    /**
     * @notice Withdraw accumulated fees to the caller
     * @dev Only callable by management or performance fee recipient.
     *      Transfers all accumulated fee shares to the caller.
     */
    function withdrawFees() external {
        _withdrawFees(msg.sender);
    }

    /**
     * @notice Withdraw accumulated fees to a specified receiver
     * @dev Only callable by management or performance fee recipient.
     *      Transfers all accumulated fee shares to the specified receiver address.
     * @param _receiver Address to receive the fee shares
     */
    function withdrawFees(address _receiver) external {
        _withdrawFees(_receiver);
    }

    /**
     * @notice Internal function to process fee withdrawals
     * @dev Validates caller authorization and transfers accumulated fee shares.
     *      Resets feeShares to 0 after transfer.
     * @param _receiver Address to receive the fee shares
     */
    function _withdrawFees(address _receiver) internal {
        require(
            msg.sender == TokenizedStrategy.management() ||
                msg.sender == TokenizedStrategy.performanceFeeRecipient(),
            "!authorized"
        );

        uint256 amount = feeShares;
        feeShares = 0;
        asset.safeTransfer(_receiver, amount);
    }
}
