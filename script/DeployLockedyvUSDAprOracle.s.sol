// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";

import {LockedVaultAprOracle} from "../src/LockedVaultAprOracle.sol";

interface IAprOracleCore {
    function setOracle(address _strategy, address _oracle) external;
}

contract DeployLockedyvUSDAprOracle is Script {
    function run() external {
        address aprOracle = vm.envAddress("APR_ORACLE");
        address lockedVault = vm.envAddress("LOCKED_VAULT");

        vm.startBroadcast();

        LockedVaultAprOracle oracle = new LockedVaultAprOracle();
        IAprOracleCore(aprOracle).setOracle(lockedVault, address(oracle));

        console.log("LockedVaultAprOracle deployed at:", address(oracle));
        console.log("AprOracle updated for:", lockedVault);

        vm.stopBroadcast();
    }
}
