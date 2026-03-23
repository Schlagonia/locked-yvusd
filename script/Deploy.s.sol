// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {LockedyvUSD} from "../src/LockedyvUSD.sol";
import {FeeSplitter} from "../src/FeeSplitter.sol";
import {ILockedyvUSD} from "../src/interfaces/ILockedyvUSD.sol";
import {LockerZapper} from "../src/LockerZapper.sol";

contract DeployScript is Script {
    address public yvUSD = 0x696d02Db93291651ED510704c9b286841d506987;

    address public governance = 0x1b5f15DCb82d25f91c65b53CEe151E8b9fBdD271;

    function run() external {
        // Load deployment parameters from environment
        string memory name = string("Locked yvUSD");

        // Start broadcast
        vm.startBroadcast();

        // Deploy LockedyvUSD
        LockedyvUSD lockedVault = new LockedyvUSD(yvUSD, name);

        console.log("LockedyvUSD deployed at:", address(lockedVault));
        console.log("Connected to yvUSD at:", yvUSD);
        console.log("Token name:", name);

        // Deploy FeeSplitter
        FeeSplitter feeSplitter = new FeeSplitter(governance);
        console.log("FeeSplitter deployed at:", address(feeSplitter));

        ILockedyvUSD lockedyvUSD = ILockedyvUSD(address(lockedVault));

        lockedyvUSD.setPerformanceFee(0);
        lockedyvUSD.setPerformanceFeeRecipient(address(feeSplitter));
        lockedyvUSD.setProfitMaxUnlockTime(7 days);

        lockedyvUSD.setFees(25, 1_000, 1_000);

        // Deploy LockerZapper
        LockerZapper lockerZapper = new LockerZapper(governance);
        console.log("LockerZapper deployed at:", address(lockerZapper));

        vm.stopBroadcast();
    }
}
