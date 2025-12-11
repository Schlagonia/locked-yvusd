// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {Governance} from "@periphery/utils/Governance.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/**
 * @title FeeSplitter
 * @notice Contract that splits tokens between different receivers based on configured ratios
 * @dev Each token can have its own split configuration using basis points (10_000 = 100%)
 */
contract FeeSplitter is Governance {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    /* ========== EVENTS ========== */

    event ReceiverAdded(address token, address receiver);
    event ReceiverRemoved(address token, address receiver);
    event SplitUpdated(
        address token,
        address receiver,
        uint256 newSplit,
        uint256 newTotalSplit
    );
    event TokenDistributed(address token, uint256 amount);

    /* ========== STATE VARIABLES ========== */

    struct TokenSplit {
        EnumerableSet.AddressSet receivers;
        mapping(address => uint256) splits;
        uint256 totalSplit;
    }

    // Basis points constants
    uint256 internal constant BASIS_POINTS = 10_000;

    // Token -> TokenSplit
    mapping(address => TokenSplit) internal tokenSplits;

    constructor(address _governance) Governance(_governance) {}

    /* ========== EXTERNAL FUNCTIONS ========== */

    /**
     * @notice Update split for an existing receiver of a specific token
     * @param _token Address of the token
     * @param _receiver Address of the receiver
     * @param _newSplit New split allocation
     */
    function updateSplit(
        address _token,
        address _receiver,
        uint256 _newSplit
    ) external onlyGovernance {
        require(
            _receiver != address(0) && _receiver != address(this),
            "invalid receiver"
        );

        uint256 oldSplit;
        // If the receiver is new to this token add them.
        if (!containsReceiver(_token, _receiver)) {
            tokenSplits[_token].receivers.add(_receiver);

            emit ReceiverAdded(_token, _receiver);
        } else {
            oldSplit = tokenSplits[_token].splits[_receiver];
        }

        uint256 newTotalSplit = tokenSplits[_token].totalSplit -
            oldSplit +
            _newSplit;
        require(newTotalSplit <= BASIS_POINTS, "Total split exceeds maximum");

        tokenSplits[_token].splits[_receiver] = _newSplit;
        tokenSplits[_token].totalSplit = newTotalSplit;

        emit SplitUpdated(_token, _receiver, _newSplit, newTotalSplit);
    }

    /**
     * @notice Remove a receiver for a specific token
     * @param _token Address of the token
     * @param _receiver Address of the receiver to remove
     */
    function removeReceiver(
        address _token,
        address _receiver
    ) external onlyGovernance {
        require(containsReceiver(_token, _receiver), "Receiver not added");

        uint256 receiverSplit = tokenSplits[_token].splits[_receiver];
        tokenSplits[_token].totalSplit -= receiverSplit;
        delete tokenSplits[_token].splits[_receiver];
        tokenSplits[_token].receivers.remove(_receiver);

        emit ReceiverRemoved(_token, _receiver);
    }

    function distributeMany(address[] memory _tokens) external {
        for (uint256 i = 0; i < _tokens.length; i++) {
            distribute(_tokens[i]);
        }
    }

    /**
     * @notice Split all accumulated tokens according to configured basis points
     * @param _token Address of the token to split
     */
    function distribute(address _token) public {
        TokenSplit storage tokenSplit = tokenSplits[_token];
        require(tokenSplit.totalSplit > 0, "Token split not configured");
        require(tokenSplit.receivers.length() > 0, "No receivers configured");

        IERC20 token = IERC20(_token);
        uint256 balance = token.balanceOf(address(this)) - 1;

        (
            address[] memory _receivers,
            uint256[] memory _splits
        ) = getReceiversAndSplits(_token);

        uint256 amount;
        for (uint i = 0; i < _receivers.length; i++) {
            amount = (balance * _splits[i]) / BASIS_POINTS;

            if (amount > 0) {
                token.safeTransfer(_receivers[i], amount);
            }
        }

        emit TokenDistributed(_token, balance);
    }

    function rescue(
        address _token,
        address _to
    ) external onlyGovernance returns (bool success) {
        uint256 balance = IERC20(_token).balanceOf(address(this));
        (success, ) = _token.call(
            abi.encodeCall(IERC20.transfer, (_to, balance))
        );
    }

    /* ========== VIEW FUNCTIONS ========== */

    /**
     * @notice Get all receivers and their basis points for a specific token
     * @param _token Address of the token
     * @return receivers_ Array of receiver addresses
     * @return splits_ Array of corresponding splits
     */
    function getReceiversAndSplits(
        address _token
    )
        public
        view
        returns (address[] memory receivers_, uint256[] memory splits_)
    {
        uint256 length = getReceiversLength(_token);
        receivers_ = tokenSplits[_token].receivers.values();
        splits_ = new uint256[](length);

        for (uint i = 0; i < length; i++) {
            splits_[i] = tokenSplits[_token].splits[receivers_[i]];
        }
    }

    /**
     * @notice Get the total split for a token
     * @param _token Address of the token
     * @return . Total split
     */
    function getTotalSplit(address _token) public view returns (uint256) {
        return tokenSplits[_token].totalSplit;
    }

    function getReceivers(
        address _token
    ) public view returns (address[] memory) {
        return tokenSplits[_token].receivers.values();
    }

    function getReceiverSplit(
        address _token,
        address _receiver
    ) public view returns (uint256) {
        return tokenSplits[_token].splits[_receiver];
    }

    /**
     * @notice Check if a token has splits configured
     * @param _token Address of the token
     * @return Whether the token has splits configured
     */
    function isTokenConfigured(address _token) external view returns (bool) {
        return tokenSplits[_token].totalSplit > 0;
    }

    function getReceiversLength(address _token) public view returns (uint256) {
        return tokenSplits[_token].receivers.length();
    }

    function getReceiverAt(
        address _token,
        uint256 index
    ) public view returns (address) {
        return tokenSplits[_token].receivers.at(index);
    }

    function containsReceiver(
        address _token,
        address receiver
    ) public view returns (bool) {
        return tokenSplits[_token].receivers.contains(receiver);
    }
}
