// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/**
 * @title LockerZapper
 * @author Yearn Finance
 * @notice A zapper contract for depositing into and withdrawing from LockedyvUSD in one transaction
 * @dev Provides convenience functions to:
 *      - zapIn: deposit base asset -> yvUSD vault -> LockedyvUSD in one transaction
 *      - zapOut: withdraw from LockedyvUSD -> yvUSD vault -> base asset in one transaction
 *      Note: zapOut requires the cooldown period to be completed on the LockedyvUSD contract
 */
contract LockerZapper {
    using SafeERC20 for IERC20;

    /// @notice The underlying base asset (e.g., USDC)
    IERC20 public immutable asset;

    /// @notice The yvUSD vault that holds the base asset
    IERC4626 public immutable yvUSD;

    /// @notice The LockedyvUSD contract that wraps yvUSD shares
    IERC4626 public immutable lockedYvUSD;

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
     * @notice Initialize the zapper with the relevant contract addresses
     * @param _asset The underlying base asset address
     * @param _yvUSD The yvUSD vault address
     * @param _lockedYvUSD The LockedyvUSD contract address
     */
    constructor(address _asset, address _yvUSD, address _lockedYvUSD) {
        require(_asset != address(0), "Invalid asset");
        require(_yvUSD != address(0), "Invalid yvUSD");
        require(_lockedYvUSD != address(0), "Invalid lockedYvUSD");

        asset = IERC20(_asset);
        yvUSD = IERC4626(_yvUSD);
        lockedYvUSD = IERC4626(_lockedYvUSD);

        // Approve yvUSD vault to spend asset
        asset.approve(_yvUSD, type(uint256).max);

        // Approve lockedYvUSD to spend yvUSD shares
        IERC20(_yvUSD).approve(_lockedYvUSD, type(uint256).max);
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
     * @dev Deposits asset into yvUSD vault, then deposits the minted yvUSD shares into LockedyvUSD
     * @param _amount Amount of base asset to deposit (type(uint256).max for full balance)
     * @param _receiver Address to receive the LockedyvUSD shares
     * @return lockedShares Amount of LockedyvUSD shares minted
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

        // Deposit asset into yvUSD vault, receiving yvUSD shares
        uint256 yvUSDShares = yvUSD.deposit(_amount, address(this));

        // Deposit yvUSD shares into LockedyvUSD, minting locked shares to receiver
        lockedShares = lockedYvUSD.deposit(yvUSDShares, _receiver);

        emit ZapIn(msg.sender, _amount, lockedShares);
    }

    /**
     * @notice Zap out of LockedyvUSD to the base asset (receiver = msg.sender)
     * @dev IMPORTANT: The user must have completed the cooldown period on LockedyvUSD before calling.
     *      User must approve this contract to spend their LockedyvUSD shares.
     * @param _shares Amount of LockedyvUSD shares to redeem (type(uint256).max for full balance)
     * @return assetAmount Amount of base asset received
     */
    function zapOut(uint256 _shares) external returns (uint256 assetAmount) {
        return zapOut(_shares, msg.sender);
    }

    /**
     * @notice Zap out of LockedyvUSD to the base asset
     * @dev Redeems LockedyvUSD shares for yvUSD shares, then redeems yvUSD shares for the base asset.
     *      IMPORTANT: The user must have completed the cooldown period on LockedyvUSD before calling.
     *      User must approve this contract to spend their LockedyvUSD shares.
     * @param _shares Amount of LockedyvUSD shares to redeem (type(uint256).max for full balance)
     * @param _receiver Address to receive the base asset
     * @return assetAmount Amount of base asset received
     */
    function zapOut(
        uint256 _shares,
        address _receiver
    ) public returns (uint256 assetAmount) {
        require(_receiver != address(0), "Invalid receiver");

        // Handle max shares
        if (_shares == type(uint256).max) {
            _shares = IERC20(address(lockedYvUSD)).balanceOf(msg.sender);
        }
        require(_shares > 0, "Shares must be > 0");

        // Redeem locked shares directly from user's wallet for yvUSD shares
        // This will revert if cooldown is not complete
        // User must have approved this contract to spend their locked shares
        uint256 yvUSDShares = lockedYvUSD.redeem(
            _shares,
            address(this),
            msg.sender
        );

        // Redeem yvUSD shares for base asset
        assetAmount = yvUSD.redeem(yvUSDShares, _receiver, address(this));

        emit ZapOut(msg.sender, _shares, assetAmount);
    }

    /**
     * @notice Preview the amount of LockedyvUSD shares that would be minted for a given asset amount
     * @param _amount Amount of base asset
     * @return lockedShares Expected amount of LockedyvUSD shares
     */
    function previewZapIn(
        uint256 _amount
    ) external view returns (uint256 lockedShares) {
        uint256 yvUSDShares = yvUSD.previewDeposit(_amount);
        lockedShares = lockedYvUSD.previewDeposit(yvUSDShares);
    }

    /**
     * @notice Preview the amount of base asset that would be received for redeeming LockedyvUSD shares
     * @param _shares Amount of LockedyvUSD shares
     * @return assetAmount Expected amount of base asset
     */
    function previewZapOut(
        uint256 _shares
    ) external view returns (uint256 assetAmount) {
        uint256 yvUSDShares = lockedYvUSD.previewRedeem(_shares);
        assetAmount = yvUSD.previewRedeem(yvUSDShares);
    }
}
