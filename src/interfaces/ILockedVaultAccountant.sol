// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

interface ILockedVaultAccountant {
    function pendingLockerShares(
        address _vault
    ) external view returns (uint256);

    function reserveVault(address _vault) external view returns (address);

    function lockerBonus(address _vault) external view returns (uint16);

    function claimableFeeShares(address _vault) external view returns (uint256);

    function availableRefundLiquidity(
        address _vault
    ) external view returns (uint256);

    function pullLockerBonus(
        address _vault
    ) external returns (uint256 _sharesPulled);
}
