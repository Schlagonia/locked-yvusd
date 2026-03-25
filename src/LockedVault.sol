// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {BaseStrategy} from "@tokenized-strategy/BaseStrategy.sol";
import {BaseHooks, ERC20} from "@periphery/Bases/Hooks/BaseHooks.sol";
import {Base4626Compounder} from "@periphery/Bases/4626Compounder/Base4626Compounder.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {IVault} from "@yearn-vaults/interfaces/IVault.sol";
import {IVaultFactory} from "@yearn-vaults/interfaces/IVaultFactory.sol";

interface IVaultCorrected {
    function FACTORY() external view returns (address);
}

contract LockedVault is BaseHooks, Base4626Compounder {
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

    struct UserCooldown {
        uint64 cooldownEnd;
        uint64 windowEnd;
        uint128 shares;
    }

    struct FeeConfig {
        uint16 managementFee;
        uint16 performanceFee;
        uint16 lockerBonus;
    }

    uint256 internal constant MAX_MANAGEMENT_FEE = 200;
    uint256 public constant MAX_COOLDOWN_DURATION = 30 days;
    uint256 internal constant SECS_PER_YEAR = 31_556_952;

    IVaultFactory public immutable VAULT_FACTORY;

    uint256 public feeShares;
    FeeConfig public feeConfig;
    uint256 public cooldownDuration;
    uint256 public withdrawalWindow;

    mapping(address => UserCooldown) public cooldowns;

    constructor(
        address _vault,
        string memory _name
    ) Base4626Compounder(IERC4626(_vault).asset(), _name, _vault) {
        VAULT_FACTORY = IVaultFactory(IVaultCorrected(_vault).FACTORY());

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
        require(msg.sender == address(vault), "only vault");

        FeeConfig memory fee = feeConfig;
        IVault.StrategyParams memory strategyParams = IVault(msg.sender)
            .strategies(_strategy);

        require(
            strategyParams.last_report != block.timestamp,
            "already reported"
        );

        _vaultHealthCheck(strategyParams.current_debt, _gain, _loss);

        if (_gain == 0) {
            return (0, 0);
        }

        uint256 managementFee;
        if (fee.managementFee > 0) {
            uint256 duration = block.timestamp - strategyParams.last_report;
            managementFee =
                (strategyParams.current_debt * duration * fee.managementFee) /
                MAX_BPS /
                SECS_PER_YEAR;
        }

        uint256 performanceFee = (_gain * fee.performanceFee) / MAX_BPS;
        uint256 lockerBonus = (_gain * fee.lockerBonus) / MAX_BPS;

        _fees = managementFee + performanceFee + lockerBonus;

        if (_fees > _gain) {
            _fees = _gain;
            managementFee = _gain - (performanceFee + lockerBonus);
        }

        if (_fees == 0) {
            return (0, 0);
        }

        uint256 expectedFeeShares = (getExpectedShares(_fees) *
            (performanceFee + managementFee)) / _fees;

        if (balanceOfVault() >= expectedFeeShares) {
            ERC20(address(vault)).safeTransfer(
                TokenizedStrategy.performanceFeeRecipient(),
                expectedFeeShares
            );
        } else {
            feeShares += expectedFeeShares;
        }

        emit FeesReported(managementFee, performanceFee, lockerBonus);
        return (_fees, 0);
    }

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
                _gain <= (_currentDebt * profitLimitRatio()) / MAX_BPS,
                "healthCheck"
            );
        } else if (_loss > 0) {
            require(
                _loss <= (_currentDebt * lossLimitRatio()) / MAX_BPS,
                "healthCheck"
            );
        }
    }

    function getExpectedShares(uint256 _fees) public view returns (uint256) {
        if (_fees == 0) {
            return 0;
        }

        uint256 totalShares = IVault(address(vault)).convertToShares(_fees);
        (uint16 protocolFee, ) = VAULT_FACTORY.protocol_fee_config(
            address(vault)
        );

        if (protocolFee > 0) {
            totalShares -= (totalShares * protocolFee) / MAX_BPS;
        }

        return totalShares;
    }

    function balanceOfVault() public view override returns (uint256) {
        uint256 rawBalance = ERC20(address(vault)).balanceOf(address(this));
        if (rawBalance <= feeShares) {
            return 0;
        }

        return rawBalance - feeShares;
    }

    function vaultsMaxWithdraw() public view override returns (uint256) {
        uint256 maxRedeemShares = IERC4626(address(vault)).maxRedeem(
            address(this)
        );
        uint256 availableShares = balanceOfVault() + balanceOfStake();
        if (maxRedeemShares > availableShares) {
            maxRedeemShares = availableShares;
        }

        return IERC4626(address(vault)).convertToAssets(maxRedeemShares);
    }

    function availableDepositLimit(
        address _owner
    ) public view override(BaseStrategy, Base4626Compounder) returns (uint256) {
        return Base4626Compounder.availableDepositLimit(_owner);
    }

    function availableWithdrawLimit(
        address _owner
    ) public view override(BaseStrategy, Base4626Compounder) returns (uint256) {
        uint256 baseLimit = Base4626Compounder.availableWithdrawLimit(_owner);

        if (cooldownDuration == 0 || TokenizedStrategy.isShutdown()) {
            return baseLimit;
        }

        UserCooldown memory cooldown = cooldowns[_owner];
        if (cooldown.shares == 0) {
            return 0;
        }

        if (block.timestamp < cooldown.cooldownEnd) {
            return 0;
        }

        if (block.timestamp > cooldown.windowEnd) {
            return 0;
        }

        uint256 cooldownAssets = TokenizedStrategy.convertToAssets(
            cooldown.shares
        );
        return baseLimit < cooldownAssets ? baseLimit : cooldownAssets;
    }

    function _emergencyWithdraw(
        uint256 _amount
    ) internal override(BaseStrategy, Base4626Compounder) {
        Base4626Compounder._emergencyWithdraw(_amount);
    }

    function startCooldown(uint256 shares) external {
        require(shares > 0, "Invalid shares");

        uint256 userBalance = TokenizedStrategy.balanceOf(msg.sender);
        require(shares <= userBalance, "Insufficient balance for cooldown");

        uint256 cooldownPeriod = cooldownDuration;
        cooldowns[msg.sender] = UserCooldown({
            cooldownEnd: uint64(block.timestamp + cooldownPeriod),
            windowEnd: uint64(
                block.timestamp + cooldownPeriod + withdrawalWindow
            ),
            shares: uint128(shares)
        });

        emit CooldownStarted(msg.sender, shares, block.timestamp);
    }

    function cancelCooldown() external {
        require(cooldowns[msg.sender].shares > 0, "No active cooldown");
        delete cooldowns[msg.sender];
        emit CooldownCancelled(msg.sender);
    }

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
        require(
            _cooldownDuration <= MAX_COOLDOWN_DURATION,
            "Cooldown duration too long"
        );
        cooldownDuration = _cooldownDuration;
        emit CooldownDurationUpdated(_cooldownDuration);
    }

    function setWithdrawalWindow(
        uint256 _withdrawalWindow
    ) external onlyManagement {
        require(_withdrawalWindow >= 1 days, "Withdrawal window too short");
        withdrawalWindow = _withdrawalWindow;
        emit WithdrawalWindowUpdated(_withdrawalWindow);
    }

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

    function withdrawFees() external {
        _withdrawFees(msg.sender);
    }

    function withdrawFees(address _receiver) external {
        _withdrawFees(_receiver);
    }

    function _withdrawFees(address _receiver) internal {
        require(
            msg.sender == TokenizedStrategy.management() ||
                msg.sender == TokenizedStrategy.performanceFeeRecipient(),
            "!authorized"
        );

        uint256 amount = feeShares;
        feeShares = 0;
        ERC20(address(vault)).safeTransfer(_receiver, amount);
    }

    function _postWithdrawHook(
        uint256,
        uint256 shares,
        address,
        address owner,
        uint256
    ) internal override {
        UserCooldown storage cooldown = cooldowns[owner];
        if (cooldown.shares == 0) {
            return;
        }

        if (shares >= cooldown.shares) {
            delete cooldowns[owner];
        } else {
            cooldown.shares -= uint128(shares);
        }
    }

    function _preTransferHook(
        address from,
        address to,
        uint256 amount
    ) internal view override {
        if (from == address(0) || to == address(0)) {
            return;
        }

        if (cooldownDuration == 0 || TokenizedStrategy.isShutdown()) {
            return;
        }

        UserCooldown memory cooldown = cooldowns[from];
        if (cooldown.shares == 0) {
            return;
        }

        uint256 userBalance = TokenizedStrategy.balanceOf(from);
        uint256 nonCooldownShares = userBalance > cooldown.shares
            ? userBalance - cooldown.shares
            : 0;

        require(
            amount <= nonCooldownShares,
            "Cannot transfer shares in cooldown"
        );
    }

    function symbol() external view returns (string memory) {
        return string(abi.encodePacked("l-", ERC20(address(vault)).symbol()));
    }
}
