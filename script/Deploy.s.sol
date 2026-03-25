// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {LockedVault} from "../src/LockedVault.sol";
import {FeeSplitter} from "../src/FeeSplitter.sol";
import {ILockedVault} from "../src/interfaces/ILockedVault.sol";

contract DeployScript is Script {
    function run() external {
        address wrappedVault = vm.envAddress("WRAPPED_VAULT");
        address governance = vm.envAddress("GOVERNANCE");
        string memory name = vm.envOr("LOCKED_TOKEN_NAME", string("Locked Vault"));

        vm.startBroadcast();

        LockedVault lockedVault = new LockedVault(wrappedVault, name);

        console.log("LockedVault deployed at:", address(lockedVault));
        console.log("Connected to wrapped vault at:", wrappedVault);
        console.log("Token name:", name);

        FeeSplitter feeSplitter = new FeeSplitter(governance);
        console.log("FeeSplitter deployed at:", address(feeSplitter));

        ILockedVault lockedStrategy = ILockedVault(address(lockedVault));

        lockedStrategy.setPerformanceFee(0);
        lockedStrategy.setPerformanceFeeRecipient(address(feeSplitter));
        lockedStrategy.setProfitMaxUnlockTime(7 days);
        lockedStrategy.setFees(25, 1_000, 1_000);
        vm.stopBroadcast();
    }
}
