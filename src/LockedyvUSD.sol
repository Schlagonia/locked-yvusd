// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {LockedVault} from "./LockedVault.sol";

contract LockedyvUSD is LockedVault {
    constructor(
        address _vault,
        string memory _name
    ) LockedVault(_vault, _name) {}
}
