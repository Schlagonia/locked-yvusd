// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {Governance} from "@periphery/utils/Governance.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IReferralDepositWrapper} from "./interfaces/IReferralDepositWrapper.sol";

/**
 * @title LockerZapper
 * @author Yearn Finance
 * @notice A zapper contract for depositing into and withdrawing from a stacked ERC4626 vault setup in one transaction
 * @dev Provides convenience functions to:
 *      - zapIn: deposit base asset -> vault -> staking vault in one transaction
 *      - zapOut: withdraw staking vault -> vault -> base asset in one transaction
 *      Note: if the staking vault enforces a cooldown, it must be completed before zapOut
 */
contract LockerZapper is Governance {
    using SafeERC20 for IERC20;

    /// @notice Referral deposit wrapper on mainnet.
    IReferralDepositWrapper public constant REFERRAL_DEPOSIT_WRAPPER =
        IReferralDepositWrapper(0x3744Df2673097d738aCaa3E463E6D638867757f2);

    /// @notice Emitted when a user zaps in from the base asset to the staking vault.
    event ZapIn(
        address indexed user,
        uint256 indexed assetAmount,
        uint256 indexed stakedShares,
        address staking
    );

    /// @notice Emitted when a user zaps out from the staking vault to the base asset.
    event ZapOut(
        address indexed user,
        uint256 indexed stakedShares,
        uint256 indexed assetAmount,
        address staking
    );

    constructor(address _governance) Governance(_governance) {}

    /**
     * @notice Zap into a staking vault from the base asset (receiver = msg.sender)
     * @param _staking Address of the staking vault
     * @param _amount Amount of base asset to deposit (type(uint256).max for full balance)
     * @return stakedShares Amount of staking shares minted
     */
    function zapIn(
        address _staking,
        uint256 _amount
    ) external returns (uint256 stakedShares) {
        return zapIn(_staking, _amount, msg.sender);
    }

    /**
     * @notice Zap into a staking vault from the base asset
     * @dev Derives the intermediate vault and base asset from the staking vault on the fly.
     * @param _staking Address of the staking vault
     * @param _amount Amount of base asset to deposit (type(uint256).max for full balance)
     * @param _receiver Address to receive the staking shares
     * @return stakedShares Amount of staking shares minted
     */
    function zapIn(
        address _staking,
        uint256 _amount,
        address _receiver
    ) public returns (uint256 stakedShares) {
        return _zapIn(_staking, _amount, _receiver, address(0));
    }

    /**
     * @notice Zap into a staking vault from the base asset while tagging a referrer
     * @dev Uses the hardcoded referral deposit wrapper for both deposit hops.
     * @param _staking Address of the staking vault
     * @param _amount Amount of base asset to deposit (type(uint256).max for full balance)
     * @param _receiver Address to receive the staking shares
     * @param _referrer Address to attribute the referral to
     * @return stakedShares Amount of staking shares minted
     */
    function zapIn(
        address _staking,
        uint256 _amount,
        address _receiver,
        address _referrer
    ) public returns (uint256 stakedShares) {
        require(_referrer != address(0), "Invalid referrer");

        return _zapIn(_staking, _amount, _receiver, _referrer);
    }

    function _zapIn(
        address _staking,
        uint256 _amount,
        address _receiver,
        address _referrer
    ) internal returns (uint256 stakedShares) {
        require(_receiver != address(0), "Invalid receiver");

        (
            IERC20 _asset,
            IERC4626 _vault,
            IERC4626 _stakingVault
        ) = _resolveStack(_staking);

        if (_amount == type(uint256).max) {
            _amount = _asset.balanceOf(msg.sender);
        }
        require(_amount > 0, "Amount must be > 0");

        _asset.safeTransferFrom(msg.sender, address(this), _amount);

        if (_referrer == address(0)) {
            uint256 vaultShares = _deposit(
                _asset,
                _vault,
                _amount,
                address(this)
            );
            stakedShares = _deposit(
                IERC20(address(_vault)),
                _stakingVault,
                vaultShares,
                _receiver
            );
        } else {
            uint256 vaultShares = _depositWithReferral(
                _vault,
                _amount,
                address(this),
                _referrer
            );
            stakedShares = _depositWithReferral(
                _stakingVault,
                vaultShares,
                _receiver,
                _referrer
            );
        }

        emit ZapIn(msg.sender, _amount, stakedShares, _staking);
    }

    /**
     * @notice Zap out of a staking vault to the base asset (receiver = msg.sender)
     * @param _staking Address of the staking vault
     * @param _shares Amount of staking shares to redeem
     *        Pass type(uint256).max to withdraw the maximum currently withdrawable amount.
     * @return assetAmount Amount of base asset received
     */
    function zapOut(
        address _staking,
        uint256 _shares
    ) external returns (uint256 assetAmount) {
        return zapOut(_staking, _shares, msg.sender, 0);
    }

    /**
     * @notice Zap out of a staking vault to the base asset
     * @param _staking Address of the staking vault
     * @param _shares Amount of staking shares to redeem
     *        Pass type(uint256).max to withdraw the maximum currently withdrawable amount.
     * @param _receiver Address to receive the base asset
     * @return assetAmount Amount of base asset received
     */
    function zapOut(
        address _staking,
        uint256 _shares,
        address _receiver
    ) public returns (uint256 assetAmount) {
        return zapOut(_staking, _shares, _receiver, 0);
    }

    /**
     * @notice Zap out of a staking vault to the base asset
     * @param _staking Address of the staking vault
     * @param _shares Amount of staking shares to redeem
     *        Pass type(uint256).max to withdraw the maximum currently withdrawable amount.
     * @param _receiver Address to receive the base asset
     * @param _minAssetAmount Minimum amount of base asset to receive
     * @return assetAmount Amount of base asset received
     */
    function zapOut(
        address _staking,
        uint256 _shares,
        address _receiver,
        uint256 _minAssetAmount
    ) public returns (uint256 assetAmount) {
        require(_receiver != address(0), "Invalid receiver");

        (, IERC4626 _vault, IERC4626 _stakingVault) = _resolveStack(_staking);
        (
            uint256 stakedSharesBurned,
            uint256 vaultShares
        ) = _withdrawFromStaking(_stakingVault, _shares);

        assetAmount = _vault.redeem(vaultShares, _receiver, address(this));
        require(assetAmount >= _minAssetAmount, "Insufficient assets received");

        emit ZapOut(msg.sender, stakedSharesBurned, assetAmount, _staking);
    }

    /**
     * @notice Preview the amount of staking shares that would be minted for a given asset amount
     * @param _staking Address of the staking vault
     * @param _amount Amount of base asset
     * @return stakedShares Expected amount of staking shares
     */
    function previewZapIn(
        address _staking,
        uint256 _amount
    ) external view returns (uint256 stakedShares) {
        (, IERC4626 _vault, IERC4626 _stakingVault) = _resolveStack(_staking);
        uint256 vaultShares = _vault.previewDeposit(_amount);
        stakedShares = _stakingVault.previewDeposit(vaultShares);
    }

    /**
     * @notice Preview the amount of base asset that would be received for redeeming staking shares
     * @param _staking Address of the staking vault
     * @param _shares Amount of staking shares
     * @return assetAmount Expected amount of base asset
     */
    function previewZapOut(
        address _staking,
        uint256 _shares
    ) external view returns (uint256 assetAmount) {
        (, IERC4626 _vault, IERC4626 _stakingVault) = _resolveStack(_staking);
        uint256 vaultShares = _stakingVault.previewRedeem(_shares);
        assetAmount = _vault.previewRedeem(vaultShares);
    }

    /**
     * @notice Sweep any ERC20 dust left in the zapper
     * @dev Only governance can call this
     * @param _token Address of the token to sweep
     * @param _receiver Address to receive the swept balance
     */
    function sweep(IERC20 _token, address _receiver) external onlyGovernance {
        require(_receiver != address(0), "Invalid receiver");
        uint256 _balance = _token.balanceOf(address(this));
        _token.safeTransfer(_receiver, _balance);
    }

    function _resolveStack(
        address _staking
    )
        internal
        view
        returns (IERC20 _asset, IERC4626 _vault, IERC4626 _stakingVault)
    {
        _stakingVault = IERC4626(_staking);
        _vault = IERC4626(_stakingVault.asset());
        _asset = IERC20(_vault.asset());
    }

    function _deposit(
        IERC20 _depositAsset,
        IERC4626 _vault,
        uint256 _assets,
        address _receiver
    ) internal returns (uint256 shares) {
        _depositAsset.forceApprove(address(_vault), _assets);
        shares = _vault.deposit(_assets, _receiver);
        _depositAsset.forceApprove(address(_vault), 0);
    }

    function _depositWithReferral(
        IERC4626 _vault,
        uint256 _assets,
        address _receiver,
        address _referrer
    ) internal returns (uint256 shares) {
        IERC20 _depositAsset = IERC20(_vault.asset());
        _depositAsset.forceApprove(address(REFERRAL_DEPOSIT_WRAPPER), _assets);
        shares = REFERRAL_DEPOSIT_WRAPPER.depositWithReferral(
            address(_vault),
            _assets,
            _receiver,
            _referrer
        );
        _depositAsset.forceApprove(address(REFERRAL_DEPOSIT_WRAPPER), 0);
    }

    function _withdrawFromStaking(
        IERC4626 _stakingVault,
        uint256 _shares
    ) internal returns (uint256 stakedSharesBurned, uint256 vaultShares) {
        if (
            _shares == type(uint256).max ||
            _shares == _stakingVault.balanceOf(msg.sender)
        ) {
            vaultShares = _stakingVault.maxWithdraw(msg.sender);
            require(vaultShares > 0, "Shares must be > 0");

            stakedSharesBurned = _stakingVault.withdraw(
                vaultShares,
                address(this),
                msg.sender
            );
            return (stakedSharesBurned, vaultShares);
        }

        require(_shares > 0, "Shares must be > 0");

        vaultShares = _stakingVault.redeem(_shares, address(this), msg.sender);
        return (_shares, vaultShares);
    }
}
