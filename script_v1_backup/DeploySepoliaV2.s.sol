// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "forge-std/Script.sol";
import "../src/ZybraGroupFactoryV2.sol";
import "../src/ZybraGroupV2.sol";

/**
 * @title DeploySepoliaV2
 * @dev Complete deployment script for ZybraGroupFactoryV2 and ZybraGroupV2 on Sepolia
 *
 * To deploy:
 * forge script script/DeploySepoliaV2.s.sol:DeploySepoliaV2 --rpc-url https://ethereum-sepolia-rpc.publicnode.com --broadcast --legacy
 */
contract DeploySepoliaV2 is Script {
    // Sepolia testnet addresses
    address constant USDC = 0x9d60E70d6d164708397E7F0aBa139589c7447255;
    address constant MORPHO_VAULT = 0xe1872D62bA3342BB34Df13f5Ba542C667841395E;

    function run() external {
        // Get deployer private key from environment
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("========================================");
        console.log("SEPOLIA TESTNET DEPLOYMENT - V2");
        console.log("========================================");
        console.log("Deployer:", deployer);
        console.log("USDC Address:", USDC);
        console.log("Morpho Vault:", MORPHO_VAULT);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // Step 1: Deploy ZybraGroupFactoryV2
        console.log("Step 1: Deploying ZybraGroupFactoryV2...");
        ZybraGroupFactoryV2 factory = new ZybraGroupFactoryV2();
        console.log("  -> Factory V2 deployed at:", address(factory));
        console.log("");

        // Step 2: Deploy ZybraGroupV2 using the factory
        console.log("Step 2: Deploying ZybraGroupV2 via Factory...");
        console.log("  Parameters:");
        console.log("    - Asset: USDC");
        console.log("    - Contribution: 100 USDC (100e6)");
        console.log("    - Cycle Duration: 1 week");
        console.log("    - Total Cycles: 5");
        console.log("    - Admin:", deployer);
        console.log("    - Vault: Morpho Vault");
        console.log("");

        address groupAddress = factory.deployGroup(
            USDC,                    // asset
            100e6,                   // contribution amount (100 USDC)
            1 weeks,                 // cycle duration (1 week)
            5,                       // total cycles
            deployer,                // admin
            MORPHO_VAULT            // vault address
        );

        console.log("  -> ZybraGroupV2 deployed at:", groupAddress);
        console.log("");

        vm.stopBroadcast();

        // Display deployment summary
        console.log("========================================");
        console.log("DEPLOYMENT COMPLETE!");
        console.log("========================================");
        console.log("");
        console.log("Deployed Contracts:");
        console.log("-------------------");
        console.log("ZybraGroupFactoryV2:", address(factory));
        console.log("ZybraGroupV2:", groupAddress);
        console.log("");
        console.log("Configuration:");
        console.log("-------------");
        console.log("USDC Token:", USDC);
        console.log("Morpho Vault:", MORPHO_VAULT);
        console.log("Admin:", deployer);
        console.log("Contribution Amount: 100 USDC");
        console.log("Cycle Duration: 1 week");
        console.log("Total Cycles: 5");
        console.log("");
        console.log("V2 Features:");
        console.log("------------");
        console.log("- Capital-weighted yield distribution");
        console.log("- NO catch-up mechanism");
        console.log("- Continuous yield claims");
        console.log("- Protocol fees: 0% -> 10% (after 40% of cycles)");
        console.log("- Natural dilution penalty for non-contributors");
        console.log("");
        console.log("Next Steps:");
        console.log("-----------");
        console.log("1. Members join: group.joinGroup(memberAddress)");
        console.log("2. Start pool: group.startGroup()");
        console.log("3. Members contribute: group.contribute()");
        console.log("4. Distribute yield: group.distributeYieldForCycle(cycleNumber)");
        console.log("5. Members claim: group.claimYield()");
        console.log("");
    }
}
