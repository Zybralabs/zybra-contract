// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/ZybraGroupFactory.sol";

/**
 * @title DeployFactoryV2Only
 * @notice Deploys ONLY the updated ZybraGroupFactory on Sepolia
 *         Reuses existing MockYieldVault and USDC contracts
 * 
 * Usage:
 *   forge script script/DeployFactoryV2Only.s.sol \
 *     --rpc-url $SEPOLIA_RPC_URL \
 *     --broadcast \
 *     --private-key $PRIVATE_KEY \
 *     --verify \
 *     --etherscan-api-key $ETHERSCAN_API_KEY
 */
contract DeployFactoryV2Only is Script {

    function run() external {
        address deployer = msg.sender;

        console.log("\n");
        console.log("======================================================================");
        console.log("  ZYBRA GROUP FACTORY V2 - REDEPLOYMENT (Sepolia)");
        console.log("======================================================================");
        console.log("\nDeployer:", deployer);
        console.log("Chain ID:", block.chainid);
        console.log("");

        vm.startBroadcast();

        // Deploy updated ZybraGroupFactory
        console.log("Deploying ZybraGroupFactory...");
        ZybraGroupFactory factory = new ZybraGroupFactory();
        console.log("ZybraGroupFactory deployed at:", address(factory));

        vm.stopBroadcast();

        // Summary
        console.log("\n");
        console.log("======================================================================");
        console.log("  DEPLOYMENT COMPLETE");
        console.log("======================================================================");
        console.log("\n  ZybraGroupFactory:", address(factory));
        console.log("\n  Existing MockYieldVault (reuse): 0xF8572c6e7cd4dD6a309094E6be47Dfe70f946dF8");
        console.log("  Existing USDC (Sepolia):          0x9d60E70d6d164708397E7F0aBa139589c7447255");
        console.log("");
        console.log("  Update these env vars:");
        console.log("  ZYBRAGROUP_FACTORY_V2_ADDRESS=<address above>");
        console.log("");
    }
}
