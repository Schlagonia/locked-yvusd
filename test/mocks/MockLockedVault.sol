// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockLockedVault is ERC4626 {
    mapping(address => uint256) public cooldownShares;

    constructor(IERC20 _asset, string memory _name, string memory _symbol) ERC4626(_asset) ERC20(_name, _symbol) {}

    function startCooldown(uint256 _shares) external {
        require(_shares > 0, "invalid shares");
        require(_shares <= balanceOf(msg.sender), "insufficient balance");
        cooldownShares[msg.sender] = _shares;
    }

    function maxWithdraw(address _owner) public view override returns (uint256) {
        return convertToAssets(cooldownShares[_owner]);
    }

    function maxRedeem(address _owner) public view override returns (uint256) {
        uint256 maxShares = convertToShares(maxWithdraw(_owner));
        uint256 balance = balanceOf(_owner);

        return maxShares < balance ? maxShares : balance;
    }

    function _withdraw(address _caller, address _receiver, address _owner, uint256 _assets, uint256 _shares)
        internal
        override
    {
        super._withdraw(_caller, _receiver, _owner, _assets, _shares);

        uint256 lockedShares = cooldownShares[_owner];
        if (_shares >= lockedShares) {
            cooldownShares[_owner] = 0;
        } else {
            cooldownShares[_owner] = lockedShares - _shares;
        }
    }
}
