// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {LockedVault} from "../src/LockedVault.sol";
import {LockedVaultAccountant} from "../src/LockedVaultAccountant.sol";
import {FeeSplitter} from "../src/FeeSplitter.sol";
import {LockerZapper} from "../src/LockerZapper.sol";
import {ILockedVault} from "../src/interfaces/ILockedVault.sol";

contract DeployScript is Script {
    function run() external {
        address wrappedVault;
        address governance;
        string memory name;
        address accountant;
        address feeRecipient;

        vm.startBroadcast();

        LockedVault lockedVault = new LockedVault(wrappedVault, name);

        console.log("LockedVault deployed at:", address(lockedVault));
        console.log("Connected to wrapped vault at:", wrappedVault);
        console.log("Token name:", name);

        if (accountant == address(0)) {
            accountant = address(new LockedVaultAccountant(
                governance
            ));
            console.log("LockedVaultAccountant deployed at:", address(accountant));
        } else {
            console.log("LockedVaultAccountant already deployed at:", accountant);
        }

        ILockedVault lockedStrategy = ILockedVault(address(lockedVault));

        lockedStrategy.setPerformanceFee(0);
        lockedStrategy.setPerformanceFeeRecipient(feeRecipient);
        lockedStrategy.setProfitMaxUnlockTime(3 days);

        LockerZapper lockerZapper = new LockerZapper();
        console.log("LockerZapper deployed at:", address(lockerZapper));
        vm.stopBroadcast();
    }
}
