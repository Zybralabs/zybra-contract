// SPDX-License-Identifier: MIT
/**
 * @title Production Deployment Script for ZybraGroup
 * @notice Deploy ZybraGroup with a REAL Morpho Vault (no code changes needed)
 * 
 * USAGE:
 *   # Testnet (with MockYieldVault)
 *   forge script script/DeployZybraV2Sepolia.s.sol --rpc-url $SEPOLIA_RPC --broadcast
 *   
 *   # Mainnet (with real Morpho Vault)
 *   VAULT_ADDRESS=0xBEEF01735c132Ada46AA9aA4c54623cAA92A64CB forge script script/DeployZybraV2Production.s.sol --rpc-url $MAINNET_RPC --broadcast
 */
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/ZybraGroup.sol";
import "../src/ZybraGroupFactory.sol";

contract DeployZybraV2Production is Script {
    // Mainnet USDC
    address constant MAINNET_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    
    // Default Morpho USDC Vault (can be overridden via env)
    address constant DEFAULT_MORPHO_VAULT = 0xBEEF01735c132Ada46AA9aA4c54623cAA92A64CB;
    
    function run() external {
        // Read vault address from environment (or use default)
        address vaultAddress = vm.envOr("VAULT_ADDRESS", DEFAULT_MORPHO_VAULT);
        address usdcAddress = vm.envOr("USDC_ADDRESS", MAINNET_USDC);
        
        address deployer = msg.sender;
        
        console.log("\n");
        console.log("======================================================================");
        console.log("  ZYBRA V2 PRODUCTION DEPLOYMENT");
        console.log("======================================================================");
        console.log("\nDeployer:", deployer);
        console.log("Chain ID:", block.chainid);
        console.log("USDC:", usdcAddress);
        console.log("Vault (Morpho):", vaultAddress);
        console.log("");

        vm.startBroadcast();

        // Deploy ZybraGroupFactory (same contract, just different vault)
        console.log("1. Deploying ZybraGroupFactory...");
        ZybraGroupFactory factory = new ZybraGroupFactory();
        console.log("   ZybraGroupFactory deployed at:", address(factory));

        vm.stopBroadcast();

        console.log("\n");
        console.log("======================================================================");
        console.log("  DEPLOYMENT COMPLETE");
        console.log("======================================================================");
        console.log("\nContract Addresses:");
        console.log("  ZybraGroupFactory:    ", address(factory));
        console.log("");
        console.log("To deploy a group, call factory.deployGroup() with:");
        console.log("  - asset:              ", usdcAddress);
        console.log("  - vault:              ", vaultAddress);
        console.log("  - contributionAmount:  e.g., 100e6 (100 USDC)");
        console.log("  - cycleDuration:       e.g., 604800 (1 week)");
        console.log("  - totalCycles:         e.g., 4");
        console.log("");
        console.log("NOTE: NO CODE CHANGES - Same contracts work with real Morpho vault!");
    }
}
