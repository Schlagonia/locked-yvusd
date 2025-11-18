// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {BaseHooks, ERC20} from "@periphery/Bases/Hooks/BaseHooks.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IVault} from "@yearn-vaults/interfaces/IVault.sol";
import {IVaultFactory} from "@yearn-vaults/interfaces/IVaultFactory.sol";

interface IVaultCorrected {
    function FACTORY() external view returns (address);
}

// NOTE: If the lockers are not a junior capital then we can do a sudse style cooldown and no earn extra yield during th period with no window.
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
        uint256 indexed lockedVaultFee
    );
    event FeesReported(
        uint256 indexed managementFee,
        uint256 indexed performanceFee,
        uint256 indexed lockedVaultFee
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
        uint16 lockedVaultFee; // Locked vault fee in basis points
    }

    uint256 internal constant MAX_MANAGEMENT_FEE = 200;

    uint256 internal constant SECS_PER_YEAR = 31_556_952;

    IVaultFactory public immutable VAULT_FACTORY;

    uint256 public feeShares;

    FeeConfig public feeConfig;

    uint256 public cooldownDuration;

    uint256 public withdrawalWindow;

    mapping(address => UserCooldown) public cooldowns;

    constructor(address _asset, string memory _name) BaseHooks(_asset, _name) {
        VAULT_FACTORY = IVaultFactory(IVaultCorrected(_asset).FACTORY());

        cooldownDuration = 14 days;
        withdrawalWindow = 7 days;
        emit CooldownDurationUpdated(cooldownDuration);
        emit WithdrawalWindowUpdated(withdrawalWindow);
    }

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

        // Charge management fees no matter gain or loss.
        uint256 managementFee;
        uint256 performanceFee;
        uint256 lockedVaultFee;

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

            lockedVaultFee = (_gain * (fee.lockedVaultFee)) / MAX_BPS;
        } else {
            return (0, 0);
        }

        _fees = managementFee + performanceFee + lockedVaultFee;

        if (_fees > _gain) {
            _fees = _gain;
            managementFee = _gain - (performanceFee + lockedVaultFee);
        }

        uint256 expectedShares = getExpectedShares(_fees);

        feeShares +=
            (expectedShares * (performanceFee + managementFee)) /
            _fees;

        emit FeesReported(managementFee, performanceFee, lockedVaultFee);
    }

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

    function _deployFunds(uint256 _amount) internal override {}

    function _freeFunds(uint256 _amount) internal override {}

    function _harvestAndReport() internal override returns (uint256) {
        return asset.balanceOf(address(this)) - feeShares;
    }

    /// @dev Post-withdraw hook to update cooldown after successful withdrawal
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

    /// @dev Enforces lock period, cooldown, and withdrawal window requirements
    /// @param _owner Address to check limit for
    /// @return Maximum withdrawal amount allowed in assets
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

    function setCooldownDuration(
        uint256 _cooldownDuration
    ) external onlyManagement {
        cooldownDuration = _cooldownDuration;
        emit CooldownDurationUpdated(cooldownDuration);
    }

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
     * @param _lockedVaultFee New locked vault fee in basis points
     */
    function setFees(
        uint16 _managementFee,
        uint16 _performanceFee,
        uint16 _lockedVaultFee
    ) external onlyManagement {
        require(
            _managementFee <= MAX_MANAGEMENT_FEE,
            "Management fee too high"
        );
        require(_performanceFee + _lockedVaultFee <= MAX_BPS, "Total too high");

        feeConfig = FeeConfig({
            managementFee: _managementFee,
            performanceFee: _performanceFee,
            lockedVaultFee: _lockedVaultFee
        });

        emit FeesUpdated(_managementFee, _performanceFee, _lockedVaultFee);
    }

    /**
     * @notice Withdraw fees for the caller
     */
    function withdrawFees() external {
        _withdrawFees(msg.sender);
    }

    /**
     * @notice Withdraw fees for a given receiver
     * @param _receiver Address to receive the fees
     */
    function withdrawFees(address _receiver) external {
        _withdrawFees(_receiver);
    }

    /**
     * @notice Internal function to withdraw fees
     * @param _receiver Address to receive the fees
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
