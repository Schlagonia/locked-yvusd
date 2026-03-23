// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

interface IReferralDepositWrapper {
    function depositWithReferral(
        address vault,
        uint256 assets,
        address receiver,
        address referrer
    ) external returns (uint256 shares);
}
