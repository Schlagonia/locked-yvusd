// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IVault} from "@yearn-vaults/interfaces/IVault.sol";

import {ILockedVault} from "./interfaces/ILockedVault.sol";
import {IMorpho, IMorphoFlashLoanCallback} from "./interfaces/IMorpho.sol";

contract LockerZapper is IMorphoFlashLoanCallback {
    using SafeERC20 for IERC20;

    event ZappedOut(
        address indexed lockedVault,
        address indexed owner,
        address indexed receiver,
        uint256 lockedShares,
        uint256 unlockedSharesOut
    );

    address public constant MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;

    function zapOut(
        address _lockedVault,
        uint256 _lockedShares,
        address _receiver,
        uint256 _minSharesOut
    ) external returns (uint256 unlockedSharesOut) {
        (
            ILockedVault lockedVault,
            IVault unlockedVault,
            IERC20 asset
        ) = _context(_lockedVault);

        asset.forceApprove(address(unlockedVault), type(uint256).max);
        asset.forceApprove(MORPHO, type(uint256).max);

        uint256 wrappedSharesBefore = unlockedVault.balanceOf(_receiver);
        uint256 assetsOut = lockedVault.previewRedeem(_lockedShares);

        IMorpho(MORPHO).flashLoan(
            address(asset),
            assetsOut,
            abi.encode(_lockedVault, msg.sender, _receiver, _lockedShares)
        );

        unlockedSharesOut =
            unlockedVault.balanceOf(_receiver) -
            wrappedSharesBefore;

        require(unlockedSharesOut >= _minSharesOut, "!min out");

        emit ZappedOut(
            _lockedVault,
            msg.sender,
            _receiver,
            _lockedShares,
            unlockedSharesOut
        );
    }

    function onMorphoFlashLoan(uint256 _assets, bytes calldata _data) external {
        require(msg.sender == MORPHO, "Not Morpho");

        (
            address lockedVaultAddress,
            address owner,
            address receiver,
            uint256 lockedShares
        ) = abi.decode(_data, (address, address, address, uint256));

        (
            ILockedVault lockedVault,
            IVault unlockedVault,
            IERC20 asset
        ) = _context(lockedVaultAddress);

        unlockedVault.deposit(_assets, receiver);

        lockedVault.redeem(lockedShares, address(this), owner);

        uint256 assetsToDeposit = asset.balanceOf(address(this)) - _assets;
        if (assetsToDeposit > 1) {
            unlockedVault.deposit(assetsToDeposit, receiver);
        }
    }

    function _context(
        address _lockedVault
    )
        internal
        view
        returns (ILockedVault lockedVault, IVault unlockedVault, IERC20 asset)
    {
        lockedVault = ILockedVault(_lockedVault);
        unlockedVault = IVault(lockedVault.vault());
        asset = IERC20(lockedVault.asset());
    }
}
