// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {LockedyvUSD} from "../src/LockedyvUSD.sol";
import {FeeSplitter} from "../src/FeeSplitter.sol";
import {ILockedyvUSD} from "../src/interfaces/ILockedyvUSD.sol";
contract DeployScript is Script {
    function run() external {
        // Load deployment parameters from environment
        address yvUSD = 0xC62fC9b0bb3D9c7a47A6af1ed30d7a4C74E37774;
        string memory name = string("Locked test yvUSD");

        // Start broadcast
        vm.startBroadcast();

        // Deploy LockedyvUSD
        LockedyvUSD lockedVault = new LockedyvUSD(yvUSD, name);

        console.log("LockedyvUSD deployed at:", address(lockedVault));
        console.log("Connected to yvUSD at:", yvUSD);
        console.log("Token name:", name);

        // Deploy FeeSplitter
        FeeSplitter feeSplitter = new FeeSplitter(address(lockedVault));
        console.log("FeeSplitter deployed at:", address(feeSplitter));

        ILockedyvUSD lockedyvUSD = ILockedyvUSD(address(lockedVault));

        lockedyvUSD.setPerformanceFee(0);
        lockedyvUSD.setPerformanceFeeRecipient(address(feeSplitter));
        lockedyvUSD.setProfitMaxUnlockTime(1 days);
        lockedyvUSD.setCooldownDuration(2 days);
        lockedyvUSD.setWithdrawalWindow(1 days);

        lockedyvUSD.setFees(25, 1_000, 1_000);

        vm.stopBroadcast();
    }
}