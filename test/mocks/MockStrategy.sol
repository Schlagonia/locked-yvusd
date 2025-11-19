// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

contract MockStrategy {
    address public immutable asset;
    address public immutable vault;
    uint256 public totalDebt;

    constructor(address _asset, address _vault) {
        asset = _asset;
        vault = _vault;
    }

    // Return the asset this strategy manages
    function totalAssets() external view returns (uint256) {
        return IERC20(asset).balanceOf(address(this));
    }

    // Allow vault to call deploy/free functions
    function deployFunds(uint256 _amount) external returns (uint256) {
        require(msg.sender == vault, "!vault");
        totalDebt += _amount;
        return _amount;
    }

    function freeFunds(uint256 _amount) external returns (uint256) {
        require(msg.sender == vault, "!vault");
        if (_amount > totalDebt) _amount = totalDebt;
        totalDebt -= _amount;
        return _amount;
    }

    // Simplified deposit/withdraw for testing
    function deposit(uint256 _amount, address) external returns (uint256) {
        IERC20(asset).transferFrom(msg.sender, address(this), _amount);
        return _amount;
    }

    function withdraw(uint256 _amount, address _receiver) external returns (uint256) {
        IERC20(asset).transfer(_receiver, _amount);
        return _amount;
    }

    // Fallback to handle any other calls
    fallback() external payable {
        // Return success for any other calls
        assembly {
            return(0, 0)
        }
    }

    receive() external payable {}
}

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}