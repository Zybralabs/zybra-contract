// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/ZybraGroup.sol";
import "../src/ZybraGroupFactory.sol";
import "../src/mocks/MockYieldVault.sol";

/**
 * @title DeployFactoryAndVault
 * @notice Deploys only MockYieldVault and ZybraGroupFactory on Sepolia
 */
contract DeployFactoryAndVault is Script {
    
    uint256 constant CONTRIBUTION_AMOUNT = 100e6;  // 100 USDC
    uint256 constant CYCLE_DURATION = 1 weeks;
    uint256 constant TOTAL_CYCLES = 4;

    function run() external {
        address deployer = msg.sender;
        address usdc = vm.envAddress("SEPOLIA_USDC");
        
        console.log("\n======================================================================");
        console.log("  ZYBRA FACTORY & VAULT DEPLOYMENT");
        console.log("======================================================================");
        console.log("\nDeployer:", deployer);
        console.log("Chain ID:", block.chainid);
        console.log("Using USDC:", usdc);
        console.log("");

        vm.startBroadcast();

        // Deploy MockYieldVault
        console.log("1. Deploying MockYieldVault...");
        MockYieldVault vault = new MockYieldVault(
            usdc,
            "Zybra Yield Vault",
            "zyUSDC",
            6
        );
        console.log("   MockYieldVault deployed at:", address(vault));
        
        // Set APY to 10%
        vault.setAnnualYieldRate(1000);
        console.log("   Annual yield rate set to 10% APY");

        // Deploy ZybraGroupFactory
        console.log("\n2. Deploying ZybraGroupFactory...");
        ZybraGroupFactory factory = new ZybraGroupFactory();
        console.log("   ZybraGroupFactory deployed at:", address(factory));

        vm.stopBroadcast();

        // Summary
        console.log("\n======================================================================");
        console.log("  DEPLOYMENT COMPLETE");
        console.log("======================================================================");
        console.log("\nContract Addresses:");
        console.log("  USDC (existing):         ", usdc);
        console.log("  MockYieldVault:          ", address(vault));
        console.log("  ZybraGroupFactory:     ", address(factory));
        console.log("\nTo create a group, call factory.deployGroup() with:");
        console.log("  - asset: ", usdc);
        console.log("  - contributionAmount: 100000000 (100 USDC)");
        console.log("  - cycleDuration: 604800 (1 week)");
        console.log("  - totalCycles: 4");
        console.log("  - admin: <your address>");
        console.log("  - vault: ", address(vault));
        console.log("  - treasury: <your treasury address>");
        console.log("");
    }
}
