// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/**
 * @title LockerZapper
 * @author Yearn Finance
 * @notice A zapper contract for depositing into and withdrawing from a locked ERC4626 vault in one transaction
 * @dev Provides convenience functions to:
 *      - zapIn: deposit base asset -> vault -> locked vault in one transaction
 *      - zapOut: withdraw from locked vault -> vault -> base asset in one transaction
 *      Note: zapOut requires the cooldown period to be completed on the locked vault
 */
contract LockerZapper {
    using SafeERC20 for IERC20;

    /// @notice The underlying base asset (e.g., USDC)
    IERC20 public immutable asset;

    /// @notice The intermediate ERC4626 vault that holds the base asset
    IERC4626 public immutable vault;

    /// @notice The locked ERC4626 vault that wraps the vault shares
    IERC4626 public immutable lockedVault;

    /// @notice Emitted when a user zaps into LockedyvUSD
    event ZapIn(
        address indexed user,
        uint256 indexed assetAmount,
        uint256 indexed lockedShares
    );

    /// @notice Emitted when a user zaps out of LockedyvUSD
    event ZapOut(
        address indexed user,
        uint256 indexed lockedShares,
        uint256 indexed assetAmount
    );

    /**
     * @notice Initialize the zapper with the relevant contract address
     * @param _lockedVault The locked vault contract address
     */
    constructor(address _lockedVault) {
        address _vault = IERC4626(_lockedVault).asset();
        address _asset = IERC4626(_vault).asset();

        asset = IERC20(_asset);
        vault = IERC4626(_vault);
        lockedVault = IERC4626(_lockedVault);

        // Approve the intermediate vault to spend asset.
        asset.forceApprove(_vault, type(uint256).max);

        // Approve the locked vault to spend intermediate vault shares.
        IERC20(_vault).forceApprove(_lockedVault, type(uint256).max);
    }

    /**
     * @notice Zap into LockedyvUSD from the base asset (receiver = msg.sender)
     * @param _amount Amount of base asset to deposit (type(uint256).max for full balance)
     * @return lockedShares Amount of LockedyvUSD shares minted
     */
    function zapIn(uint256 _amount) external returns (uint256 lockedShares) {
        return zapIn(_amount, msg.sender);
    }

    /**
     * @notice Zap into LockedyvUSD from the base asset
     * @dev Deposits asset into the intermediate vault, then deposits the minted vault shares into the locked vault
     * @param _amount Amount of base asset to deposit (type(uint256).max for full balance)
     * @param _receiver Address to receive the locked shares
     * @return lockedShares Amount of locked shares minted
     */
    function zapIn(
        uint256 _amount,
        address _receiver
    ) public returns (uint256 lockedShares) {
        require(_receiver != address(0), "Invalid receiver");

        // Handle max amount
        if (_amount == type(uint256).max) {
            _amount = asset.balanceOf(msg.sender);
        }
        require(_amount > 0, "Amount must be > 0");

        // Transfer asset from user to this contract
        asset.safeTransferFrom(msg.sender, address(this), _amount);

        // Deposit asset into the intermediate vault, receiving vault shares.
        uint256 vaultShares = vault.deposit(_amount, address(this));

        // Deposit vault shares into the locked vault, minting locked shares to receiver.
        lockedShares = lockedVault.deposit(vaultShares, _receiver);

        emit ZapIn(msg.sender, _amount, lockedShares);
    }

    /**
     * @notice Zap out of LockedyvUSD to the base asset (receiver = msg.sender)
     * @dev IMPORTANT: The user must have completed the cooldown period on LockedyvUSD before calling.
     *      User must approve this contract to spend their LockedyvUSD shares.
     * @param _shares Amount of locked shares to redeem
     *        Pass type(uint256).max to withdraw the maximum currently withdrawable amount.
     * @return assetAmount Amount of base asset received
     */
    function zapOut(uint256 _shares) external returns (uint256 assetAmount) {
        return zapOut(_shares, msg.sender, 0);
    }

    /**
     * @notice Zap out of LockedyvUSD to the base asset
     * @dev Redeems locked shares for vault shares, then redeems vault shares for the base asset.
     *      IMPORTANT: The user must have completed the cooldown period on LockedyvUSD before calling.
     *      User must approve this contract to spend their LockedyvUSD shares.
     * @param _shares Amount of locked shares to redeem
     *        Pass type(uint256).max to withdraw the maximum currently withdrawable amount.
     * @param _receiver Address to receive the base asset
     * @return assetAmount Amount of base asset received
     */
    function zapOut(
        uint256 _shares,
        address _receiver
    ) public returns (uint256 assetAmount) {
        return zapOut(_shares, _receiver, 0);
    }

    /**
     * @notice Zap out of LockedyvUSD to the base asset
     * @dev Redeems locked shares for vault shares, then redeems vault shares for the base asset.
     *      IMPORTANT: The user must have completed the cooldown period on LockedyvUSD before calling.
     *      User must approve this contract to spend their LockedyvUSD shares.
     * @param _shares Amount of locked shares to redeem
     *        Pass type(uint256).max to withdraw the maximum currently withdrawable amount.
     * @param _receiver Address to receive the base asset
     * @param _minAssetAmount Minimum amount of base asset to receive
     * @return assetAmount Amount of base asset received
     */
    function zapOut(
        uint256 _shares,
        address _receiver,
        uint256 _minAssetAmount
    ) public returns (uint256 assetAmount) {
        require(_receiver != address(0), "Invalid receiver");

        (
            uint256 lockedSharesBurned,
            uint256 vaultShares
        ) = _withdrawFromLockedVault(_shares);

        // Redeem vault shares for the base asset.
        assetAmount = vault.redeem(vaultShares, _receiver, address(this));

        require(assetAmount >= _minAssetAmount, "Insufficient assets received");

        emit ZapOut(msg.sender, lockedSharesBurned, assetAmount);
    }

    function _withdrawFromLockedVault(
        uint256 _shares
    ) internal returns (uint256 lockedSharesBurned, uint256 vaultShares) {
        if (_shares == type(uint256).max) {
            // Use maxWithdraw + withdraw to burn the full withdrawable share balance even when maxRedeem rounds down.
            vaultShares = lockedVault.maxWithdraw(msg.sender);
            require(vaultShares > 0, "Shares must be > 0");

            lockedSharesBurned = lockedVault.withdraw(
                vaultShares,
                address(this),
                msg.sender
            );
            return (lockedSharesBurned, vaultShares);
        }

        require(_shares > 0, "Shares must be > 0");

        // Redeem locked shares directly from the user's wallet for vault shares.
        // This will revert if cooldown is not complete.
        // User must have approved this contract to spend their locked shares.
        vaultShares = lockedVault.redeem(_shares, address(this), msg.sender);

        return (_shares, vaultShares);
    }

    /**
     * @notice Preview the amount of LockedyvUSD shares that would be minted for a given asset amount
     * @param _amount Amount of base asset
     * @return lockedShares Expected amount of LockedyvUSD shares
     */
    function previewZapIn(
        uint256 _amount
    ) external view returns (uint256 lockedShares) {
        uint256 vaultShares = vault.previewDeposit(_amount);
        lockedShares = lockedVault.previewDeposit(vaultShares);
    }

    /**
     * @notice Preview the amount of base asset that would be received for redeeming LockedyvUSD shares
     * @param _shares Amount of LockedyvUSD shares
     * @return assetAmount Expected amount of base asset
     */
    function previewZapOut(
        uint256 _shares
    ) external view returns (uint256 assetAmount) {
        uint256 vaultShares = lockedVault.previewRedeem(_shares);
        assetAmount = vault.previewRedeem(vaultShares);
    }
}
