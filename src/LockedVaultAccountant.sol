// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Governance} from "@periphery/utils/Governance.sol";

import {IVault} from "@yearn-vaults/interfaces/IVault.sol";
import {IVaultFactory} from "@yearn-vaults/interfaces/IVaultFactory.sol";

import {ILockedVault} from "./interfaces/ILockedVault.sol";

interface IVaultCorrected {
    function FACTORY() external view returns (address);
}

contract LockedVaultAccountant is Governance {
    using Math for uint256;
    using SafeERC20 for IERC20;

    event VaultConfigUpdated(
        address indexed vault,
        address indexed locker,
        uint16 managementFee,
        uint16 performanceFee,
        uint16 lockerBonus,
        uint16 refundRatio
    );
    event ReserveVaultUpdated(
        address indexed vault,
        address indexed reserveVault
    );
    event FeeSharesSwept(
        address indexed vault,
        address indexed receiver,
        uint256 shares
    );
    event FeesReported(
        address indexed vault,
        address indexed locker,
        uint256 managementFee,
        uint256 performanceFee,
        uint256 lockerBonusFee,
        uint256 refunds
    );

    uint256 internal constant MAX_BPS = 10_000;
    uint256 internal constant MAX_MANAGEMENT_FEE = 200;
    uint256 internal constant SECS_PER_YEAR = 31_556_952;

    struct VaultConfig {
        address locker;
        address reserveVault;
        uint16 managementFee;
        uint16 performanceFee;
        uint16 lockerBonus;
        uint16 refundRatio;
        uint256 pendingLockerShares;
    }

    mapping(address => VaultConfig) internal vaultConfigs;

    constructor(address _governance) Governance(_governance) {}

    function report(
        address _strategy,
        uint256 _gain,
        uint256 _loss
    ) external returns (uint256 _fees, uint256 _refunds) {
        VaultConfig storage config = vaultConfigs[msg.sender];
        require(config.locker != address(0), "!vault");

        IVault.StrategyParams memory strategyParams = IVault(msg.sender)
            .strategies(_strategy);

        require(
            strategyParams.last_report != block.timestamp,
            "already reported"
        );

        _healthCheck(config.locker, strategyParams.current_debt, _gain, _loss);

        uint256 managementFee;
        uint256 performanceFee;
        uint256 lockerBonusFee;

        if (_gain > 0) {
            if (config.managementFee > 0) {
                uint256 duration = block.timestamp - strategyParams.last_report;
                managementFee =
                    (strategyParams.current_debt *
                        duration *
                        config.managementFee) /
                    MAX_BPS /
                    SECS_PER_YEAR;
            }

            performanceFee = (_gain * config.performanceFee) / MAX_BPS;
            lockerBonusFee = (_gain * config.lockerBonus) / MAX_BPS;

            _fees = managementFee + performanceFee + lockerBonusFee;
            if (_fees > _gain) {
                _fees = _gain;
                managementFee = _gain - (performanceFee + lockerBonusFee);
            }
        }

        if (_loss > 0 && config.refundRatio > 0) {
            uint256 requestedRefund = (_loss * config.refundRatio) / MAX_BPS;
            _refunds = _prepareRefunds(IVault(msg.sender), requestedRefund);
        }

        if (_fees > 0) {
            // Get the expected fee shares based on the fees reported.
            uint256 expectedLockerShares = (getExpectedShares(
                IVault(msg.sender),
                _fees
            ) * lockerBonusFee) / _fees;
            config.pendingLockerShares += expectedLockerShares;
        }

        emit FeesReported(
            msg.sender,
            config.locker,
            managementFee,
            performanceFee,
            lockerBonusFee,
            _refunds
        );
    }

    /**
     * @notice Calculates expected shares after protocol fee deduction
     * @dev Computes the net shares that will be received after the vault factory
     *      takes its protocol fee cut. Used during fee reporting to accurately
     *      track fee shares.
     * @param _fees The fee amount in asset tokens
     * @return The net shares after protocol fee deduction
     */
    function getExpectedShares(
        IVault _vault,
        uint256 _fees
    ) public view returns (uint256) {
        if (_fees == 0) return 0;

        uint256 totalShares = _vault.convertToShares(_fees);
        (uint16 protocolFee, ) = IVaultFactory(
            IVaultCorrected(address(_vault)).FACTORY()
        ).protocol_fee_config(address(_vault));

        if (protocolFee > 0) {
            uint256 protocolShares = (totalShares * protocolFee) / MAX_BPS;
            totalShares -= protocolShares;
        }

        return totalShares;
    }

    function getVaultConfig(
        address _vault
    ) external view returns (VaultConfig memory) {
        return vaultConfigs[_vault];
    }

    function pendingLockerShares(
        address _vault
    ) external view returns (uint256) {
        return vaultConfigs[_vault].pendingLockerShares;
    }

    function reserveVault(address _vault) external view returns (address) {
        return vaultConfigs[_vault].reserveVault;
    }

    function lockerBonus(address _vault) external view returns (uint16) {
        return vaultConfigs[_vault].lockerBonus;
    }

    function claimableFeeShares(address _vault) public view returns (uint256) {
        uint256 totalShares = IERC20(_vault).balanceOf(address(this));
        uint256 reservedShares = vaultConfigs[_vault].pendingLockerShares;

        if (totalShares <= reservedShares) {
            return 0;
        }

        return totalShares - reservedShares;
    }

    function availableRefundLiquidity(
        address _vault
    ) public view returns (uint256) {
        IVault vault = IVault(_vault);
        uint256 available = IERC20(vault.asset()).balanceOf(address(this));
        address configuredReserveVault = vaultConfigs[_vault].reserveVault;
        if (configuredReserveVault != address(0)) {
            available += IERC4626(configuredReserveVault).maxWithdraw(
                address(this)
            );
        }

        return available;
    }

    function setVaultConfig(
        address _vault,
        address _locker,
        uint16 _managementFee,
        uint16 _performanceFee,
        uint16 _lockerBonus,
        uint16 _refundRatio
    ) external onlyGovernance {
        require(_vault != address(0), "!vault");
        require(
            _locker != address(0) && ILockedVault(_locker).vault() == _vault,
            "!locker"
        );
        require(
            _managementFee <= MAX_MANAGEMENT_FEE,
            "management fee too high"
        );
        require(
            _performanceFee + _lockerBonus <= MAX_BPS,
            "total fees too high"
        );
        require(_refundRatio <= MAX_BPS, "refund ratio too high");

        VaultConfig storage config = vaultConfigs[_vault];
        config.locker = _locker;
        config.managementFee = _managementFee;
        config.performanceFee = _performanceFee;
        config.lockerBonus = _lockerBonus;
        config.refundRatio = _refundRatio;

        emit VaultConfigUpdated(
            _vault,
            _locker,
            _managementFee,
            _performanceFee,
            _lockerBonus,
            _refundRatio
        );
    }

    // NOTE: A reserve vault can be used by multiple vaults with the same asset.
    function setReserveVault(
        address _vault,
        address _reserveVault
    ) external onlyGovernance {
        require(_vault != address(0), "!vault");
        require(vaultConfigs[_vault].locker != address(0), "!vault");
        require(vaultConfigs[_reserveVault].locker == address(0), "!reserve");
        require(
            _reserveVault == address(0) ||
                IERC4626(_reserveVault).asset() == IVault(_vault).asset(),
            "invalid reserve vault"
        );

        vaultConfigs[_vault].reserveVault = _reserveVault;
        emit ReserveVaultUpdated(_vault, _reserveVault);
    }

    function deployIdleToReserve(
        address _vault,
        uint256 _assets
    ) external onlyGovernance returns (uint256 _shares) {
        address configuredReserveVault = vaultConfigs[_vault].reserveVault;
        require(configuredReserveVault != address(0), "invalid reserve vault");

        IERC20(IVault(_vault).asset()).forceApprove(
            configuredReserveVault,
            _assets
        );
        _shares = IERC4626(configuredReserveVault).deposit(
            _assets,
            address(this)
        );
    }

    function redeemFromReserve(
        address _vault,
        uint256 _shares
    ) external onlyGovernance returns (uint256 _assets) {
        address configuredReserveVault = vaultConfigs[_vault].reserveVault;
        require(configuredReserveVault != address(0), "invalid reserve vault");

        _assets = IERC4626(configuredReserveVault).redeem(
            _shares,
            address(this),
            address(this)
        );
    }

    function sweepFees(
        address _asset,
        uint256 _amount,
        address _receiver
    ) external onlyGovernance {
        VaultConfig storage config = vaultConfigs[_asset];
        uint256 claimable;
        if (config.locker != address(0)) {
            claimable = claimableFeeShares(_asset);
        } else {
            claimable = IERC20(_asset).balanceOf(address(this));
        }

        claimable = Math.min(claimable, _amount);
        if (claimable > 0) {
            IERC20(_asset).safeTransfer(_receiver, claimable);
        }
    }

    function pullLockerBonus(
        address _vault
    ) external returns (uint256 _sharesPulled) {
        VaultConfig storage config = vaultConfigs[_vault];
        require(config.locker != address(0), "!vault");

        _sharesPulled = config.pendingLockerShares;
        if (_sharesPulled == 0) {
            return 0;
        }

        config.pendingLockerShares = 0;
        IERC20(_vault).safeTransfer(config.locker, _sharesPulled);
    }

    function _prepareRefunds(
        IVault _vault,
        uint256 _requestedRefund
    ) internal returns (uint256 _refunds) {
        if (_requestedRefund == 0) {
            return 0;
        }

        IERC20 asset = IERC20(_vault.asset());
        uint256 looseBalance = asset.balanceOf(address(this));
        _refunds = _requestedRefund;

        if (looseBalance < _refunds) {
            address configuredReserveVault = vaultConfigs[address(_vault)]
                .reserveVault;
            if (configuredReserveVault != address(0)) {
                uint256 missing = _refunds - looseBalance;
                uint256 withdrawable = IERC4626(configuredReserveVault)
                    .maxWithdraw(address(this));
                uint256 assetsToWithdraw = withdrawable < missing
                    ? withdrawable
                    : missing;

                if (assetsToWithdraw > 0) {
                    IERC4626(configuredReserveVault).withdraw(
                        assetsToWithdraw,
                        address(this),
                        address(this)
                    );
                    looseBalance = asset.balanceOf(address(this));
                }
            }

            if (looseBalance < _refunds) {
                _refunds = looseBalance;
            }
        }

        asset.forceApprove(address(_vault), _refunds);
    }

    function _healthCheck(
        address _locker,
        uint256 _currentDebt,
        uint256 _gain,
        uint256 _loss
    ) internal view {
        ILockedVault locker = ILockedVault(_locker);
        if (!locker.doHealthCheck()) {
            return;
        }

        if (_gain > 0) {
            require(
                _gain <= (_currentDebt * locker.profitLimitRatio()) / MAX_BPS,
                "healthCheck"
            );
        } else if (_loss > 0) {
            require(
                _loss <= (_currentDebt * locker.lossLimitRatio()) / MAX_BPS,
                "healthCheck"
            );
        }
    }
}
