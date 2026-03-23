// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IReferralDepositWrapper} from "../../src/interfaces/IReferralDepositWrapper.sol";

contract MockReferralDepositWrapper is IReferralDepositWrapper {
    using SafeERC20 for IERC20;

    event ReferralDeposit(
        address receiver, address indexed referrer, address indexed vault, uint256 assets, uint256 shares
    );

    uint256 public depositCalls;
    address public lastVault;
    address public lastReceiver;
    address public lastReferrer;
    mapping(address => uint256) public referralCalls;

    function depositWithReferral(address _vault, uint256 _assets, address _receiver, address _referrer)
        external
        returns (uint256 shares)
    {
        IERC20 depositAsset = IERC20(IERC4626(_vault).asset());
        depositAsset.safeTransferFrom(msg.sender, address(this), _assets);
        depositAsset.forceApprove(_vault, _assets);
        shares = IERC4626(_vault).deposit(_assets, _receiver);
        depositAsset.forceApprove(_vault, 0);

        depositCalls += 1;
        lastVault = _vault;
        lastReceiver = _receiver;
        lastReferrer = _referrer;
        referralCalls[_referrer] += 1;

        emit ReferralDeposit(_receiver, _referrer, _vault, _assets, shares);
    }
}
