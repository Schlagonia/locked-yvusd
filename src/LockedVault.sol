// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {BaseStrategy} from "@tokenized-strategy/BaseStrategy.sol";
import {BaseHooks, ERC20} from "@periphery/Bases/Hooks/BaseHooks.sol";
import {Base4626Compounder} from "@periphery/Bases/4626Compounder/Base4626Compounder.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {IVault} from "@yearn-vaults/interfaces/IVault.sol";

import {ILockedVaultAccountant} from "./interfaces/ILockedVaultAccountant.sol";

contract LockedVault is BaseHooks, Base4626Compounder {
    event CooldownDurationUpdated(uint256 indexed newCooldownDuration);
    event WithdrawalWindowUpdated(uint256 indexed newWithdrawalWindow);
    event CooldownStarted(
        address indexed user,
        uint256 indexed shares,
        uint256 indexed timestamp
    );
    event CooldownCancelled(address indexed user);

    struct UserCooldown {
        uint64 cooldownEnd;
        uint64 windowEnd;
        uint128 shares;
    }

    uint256 public constant MAX_COOLDOWN_DURATION = 30 days;
    uint256 public constant MIN_WITHDRAWAL_WINDOW = 1 days;
    address public constant GOVERNANCE =
        0x88Ba032be87d5EF1fbE87336B7090767F367BF73;

    uint256 public cooldownDuration;

    uint256 public withdrawalWindow;

    mapping(address => UserCooldown) public cooldowns;

    modifier onlyGovernance() {
        require(msg.sender == GOVERNANCE, "Not governance");
        _;
    }

    constructor(
        address _vault,
        string memory _name
    ) Base4626Compounder(IERC4626(_vault).asset(), _name, _vault) {
        cooldownDuration = 14 days;
        withdrawalWindow = 7 days;

        emit CooldownDurationUpdated(cooldownDuration);
        emit WithdrawalWindowUpdated(withdrawalWindow);
    }

    function availableDepositLimit(
        address _owner
    ) public view override(BaseStrategy, Base4626Compounder) returns (uint256) {
        return Base4626Compounder.availableDepositLimit(_owner);
    }

    function availableWithdrawLimit(
        address _owner
    ) public view override(BaseStrategy, Base4626Compounder) returns (uint256) {
        uint256 baseLimit = Base4626Compounder.availableWithdrawLimit(_owner);

        if (cooldownDuration == 0 || TokenizedStrategy.isShutdown()) {
            return baseLimit;
        }

        UserCooldown memory cooldown = cooldowns[_owner];
        if (cooldown.shares == 0) {
            return 0;
        }

        if (block.timestamp < cooldown.cooldownEnd) {
            return 0;
        }

        if (block.timestamp > cooldown.windowEnd) {
            return 0;
        }

        uint256 cooldownAssets = TokenizedStrategy.convertToAssets(
            cooldown.shares
        );
        return baseLimit < cooldownAssets ? baseLimit : cooldownAssets;
    }

    function _emergencyWithdraw(
        uint256 _amount
    ) internal override(BaseStrategy, Base4626Compounder) {
        Base4626Compounder._emergencyWithdraw(_amount);
    }

    function startCooldown(uint256 shares) external {
        require(shares > 0, "Invalid shares");

        uint256 userBalance = TokenizedStrategy.balanceOf(msg.sender);
        require(shares <= userBalance, "Insufficient balance for cooldown");

        uint256 cooldownPeriod = cooldownDuration;
        cooldowns[msg.sender] = UserCooldown({
            cooldownEnd: uint64(block.timestamp + cooldownPeriod),
            windowEnd: uint64(
                block.timestamp + cooldownPeriod + withdrawalWindow
            ),
            shares: uint128(shares)
        });

        emit CooldownStarted(msg.sender, shares, block.timestamp);
    }

    function cancelCooldown() external {
        require(cooldowns[msg.sender].shares > 0, "No active cooldown");
        delete cooldowns[msg.sender];
        emit CooldownCancelled(msg.sender);
    }

    function getCooldownStatus(
        address user
    )
        external
        view
        returns (uint256 cooldownEnd, uint256 windowEnd, uint256 shares)
    {
        UserCooldown memory cooldown = cooldowns[user];
        return (cooldown.cooldownEnd, cooldown.windowEnd, cooldown.shares);
    }

    function setCooldownDuration(
        uint256 _cooldownDuration
    ) external onlyGovernance {
        require(
            _cooldownDuration <= MAX_COOLDOWN_DURATION,
            "Cooldown duration too long"
        );
        cooldownDuration = _cooldownDuration;
        emit CooldownDurationUpdated(_cooldownDuration);
    }

    function setWithdrawalWindow(
        uint256 _withdrawalWindow
    ) external onlyGovernance {
        require(
            _withdrawalWindow >= MIN_WITHDRAWAL_WINDOW,
            "Withdrawal window too short"
        );
        withdrawalWindow = _withdrawalWindow;
        emit WithdrawalWindowUpdated(_withdrawalWindow);
    }

    function _preReportHook() internal override {
        address accountant = IVault(address(vault)).accountant();
        if (accountant == address(0)) {
            return;
        }

        ILockedVaultAccountant(accountant).pullLockerBonus(address(vault));
    }

    function _postWithdrawHook(
        uint256,
        uint256 shares,
        address,
        address owner,
        uint256
    ) internal override {
        UserCooldown storage cooldown = cooldowns[owner];
        if (cooldown.shares == 0) {
            return;
        }

        if (shares >= cooldown.shares) {
            delete cooldowns[owner];
        } else {
            cooldown.shares -= uint128(shares);
        }
    }

    function _preTransferHook(
        address from,
        address to,
        uint256 amount
    ) internal view override {
        if (from == address(0) || to == address(0)) {
            return;
        }

        if (cooldownDuration == 0 || TokenizedStrategy.isShutdown()) {
            return;
        }

        UserCooldown memory cooldown = cooldowns[from];
        if (cooldown.shares == 0) {
            return;
        }

        uint256 userBalance = TokenizedStrategy.balanceOf(from);
        uint256 nonCooldownShares = userBalance > cooldown.shares
            ? userBalance - cooldown.shares
            : 0;

        require(
            amount <= nonCooldownShares,
            "Cannot transfer shares in cooldown"
        );
    }

    function symbol() external view returns (string memory) {
        return string(abi.encodePacked("l-", ERC20(address(vault)).symbol()));
    }
}
