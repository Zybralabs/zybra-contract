// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "forge-std/Script.sol";
import "../src/ZybraGroupFactory.sol";

/**
 * @title DeployZybraGroupFactory
 * @dev Deployment script for the ZybraGroupFactory contract
 */
contract DeployZybraGroupFactory is Script {
    function run() external {
        vm.startBroadcast();

        // Deploy the factory (no default vault needed - specify per group)
        ZybraGroupFactory factory = new ZybraGroupFactory();

        console.log("ZybraGroupFactory deployed at:", address(factory));
        console.log("Factory owner:", factory.owner());
        console.log("");
        console.log("Note: Specify vault address when deploying each group");
        console.log("Use: factory.deployGroup(asset, amount, cycleLength, admin, vault, startTime)");

        vm.stopBroadcast();
    }
}