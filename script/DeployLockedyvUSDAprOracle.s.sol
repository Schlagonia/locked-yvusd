// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";

import {LockedyvUSDAprOracle} from "../src/LockedyvUSDAprOracle.sol";

interface IAprOracleCore {
    function setOracle(address _strategy, address _oracle) external;
}

contract DeployLockedyvUSDAprOracle is Script {
    address public constant APR_ORACLE =
        0x1981AD9F44F2EA9aDd2dC4AD7D075c102C70aF92;
    address public constant LOCKED_YVUSD =
        0xAb9018A699003a777d690c156045DfC4A7ef3A96;

    function run() external {
        vm.startBroadcast();

        LockedyvUSDAprOracle oracle = new LockedyvUSDAprOracle();
        IAprOracleCore(APR_ORACLE).setOracle(LOCKED_YVUSD, address(oracle));

        console.log("LockedyvUSDAprOracle deployed at:", address(oracle));
        console.log("AprOracle updated for:", LOCKED_YVUSD);

        vm.stopBroadcast();
    }
}
