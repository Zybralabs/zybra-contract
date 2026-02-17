// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/ZybraGroupFactoryV2.sol";

/**
 * @title DeployFactoryV2Only
 * @notice Deploys ONLY the updated ZybraGroupFactoryV2 on Sepolia
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

        // Deploy updated ZybraGroupFactoryV2
        console.log("Deploying ZybraGroupFactoryV2...");
        ZybraGroupFactoryV2 factory = new ZybraGroupFactoryV2();
        console.log("ZybraGroupFactoryV2 deployed at:", address(factory));

        vm.stopBroadcast();

        // Summary
        console.log("\n");
        console.log("======================================================================");
        console.log("  DEPLOYMENT COMPLETE");
        console.log("======================================================================");
        console.log("\n  ZybraGroupFactoryV2:", address(factory));
        console.log("\n  Existing MockYieldVault (reuse): 0xeba97f1ba3993a3167dd77292f27d5dcc42dec69");
        console.log("  Existing USDC (Sepolia):          0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238");
        console.log("");
        console.log("  Update these env vars:");
        console.log("  ZYBRAGROUP_FACTORY_V2_ADDRESS=<address above>");
        console.log("");
    }
}
