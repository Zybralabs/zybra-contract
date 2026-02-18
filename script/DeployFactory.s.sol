// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/ZybraGroupFactory.sol";

/**
 * @title DeployFactory
 * @notice Deploys the ZybraGroupFactory on Sepolia
 *
 * Usage:
 *   forge script script/DeployFactory.s.sol \
 *     --rpc-url $SEPOLIA_RPC_URL \
 *     --broadcast \
 *     --private-key $PRIVATE_KEY \
 *     --verify \
 *     --etherscan-api-key $ETHERSCAN_API_KEY
 */
contract DeployFactory is Script {
    function run() external {
        address deployer = msg.sender;

        console.log("======================================================================");
        console.log("  ZYBRA GROUP FACTORY - DEPLOYMENT (Sepolia)");
        console.log("======================================================================");
        console.log("Deployer:", deployer);
        console.log("Chain ID:", block.chainid);

        vm.startBroadcast();

        ZybraGroupFactory factory = new ZybraGroupFactory();
        console.log("ZybraGroupFactory deployed at:", address(factory));

        vm.stopBroadcast();

        console.log("======================================================================");
        console.log("  DEPLOYMENT COMPLETE");
        console.log("======================================================================");
        console.log("  ZybraGroupFactory:", address(factory));
        console.log("  Update subgraph.yaml with this address");
        console.log("======================================================================");
    }
}
