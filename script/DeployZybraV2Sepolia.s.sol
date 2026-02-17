// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/ZybraGroupV2.sol";
import "../src/ZybraGroupFactoryV2.sol";
import "../src/mocks/MockYieldVault.sol";
import "../src/treasury/Treasury.sol";
import "../src/treasury/FeeCollector.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title DeployZybraV2Sepolia
 * @notice Deploys ZybraGroupV2 ecosystem on Sepolia using existing USDC
 * 
 * Usage:
 *   forge script script/DeployZybraV2Sepolia.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast --private-key $PRIVATE_KEY --verify
 */
contract DeployZybraV2Sepolia is Script {
    
    // Deployment parameters
    uint256 constant CONTRIBUTION_AMOUNT = 100e6;  // 100 USDC
    uint256 constant CYCLE_DURATION = 1 weeks;      // 1 week cycles
    uint256 constant TOTAL_CYCLES = 4;              // 4 cycles total

    function run() external {
        address deployer = msg.sender;
        address usdc = vm.envAddress("SEPOLIA_USDC");
        
        console.log("\n");
        console.log("======================================================================");
        console.log("  ZYBRA V2 SEPOLIA DEPLOYMENT");
        console.log("======================================================================");
        console.log("\nDeployer:", deployer);
        console.log("Chain ID:", block.chainid);
        console.log("Using USDC:", usdc);
        console.log("");

        vm.startBroadcast();

        // ============ 1. Deploy Treasury & FeeCollector ============
        console.log("1. Deploying Treasury & FeeCollector...");
        Treasury treasury = new Treasury(deployer, deployer);
        console.log("   Treasury deployed at:", address(treasury));

        FeeCollector feeCollector = new FeeCollector(address(treasury), deployer, deployer);
        console.log("   FeeCollector deployed at:", address(feeCollector));

        // Grant FeeCollector the COLLECTOR_ROLE on Treasury
        bytes32 collectorRole = treasury.COLLECTOR_ROLE();
        treasury.grantRole(collectorRole, address(feeCollector));
        console.log("   COLLECTOR_ROLE granted to FeeCollector");

        // ============ 2. Deploy Mock Yield Vault ============
        console.log("\n2. Deploying MockYieldVault (ERC4626 with time-based yield)...");
        MockYieldVault vault = new MockYieldVault(
            usdc,
            "Zybra Yield Vault",
            "zyUSDC",
            6
        );
        console.log("   MockYieldVault deployed at:", address(vault));
        
        // Set APY to 10% (1000 bps)
        vault.setAnnualYieldRate(1000);
        console.log("   Annual yield rate set to 10% APY");

        // ============ 3. Deploy ZybraGroupFactoryV2 ============
        console.log("\n3. Deploying ZybraGroupFactoryV2...");
        ZybraGroupFactoryV2 factory = new ZybraGroupFactoryV2();
        console.log("   ZybraGroupFactoryV2 deployed at:", address(factory));

        // ============ 4. Deploy a Sample ZybraGroupV2 ============
        console.log("\n4. Creating ZybraGroupV2 via factory...");
        console.log("   Parameters:");
        console.log("   - USDC:", usdc);
        console.log("   - Contribution:", CONTRIBUTION_AMOUNT / 1e6, "USDC");
        console.log("   - Cycle Duration:", CYCLE_DURATION / 1 days, "days");
        console.log("   - Total Cycles:", TOTAL_CYCLES);
        console.log("   - Admin:", deployer);
        console.log("   - Vault:", address(vault));
        console.log("   - Treasury:", address(treasury));

        address groupAddress = factory.deployGroup(
            usdc,
            CONTRIBUTION_AMOUNT,
            CYCLE_DURATION,
            TOTAL_CYCLES,
            deployer,
            address(vault),
            address(treasury)
        );
        console.log("   ZybraGroupV2 deployed at:", groupAddress);

        // Register group in FeeCollector
        feeCollector.registerSource(groupAddress);
        console.log("   Group registered in FeeCollector");

        vm.stopBroadcast();

        // ============ Summary ============
        console.log("\n");
        console.log("======================================================================");
        console.log("  DEPLOYMENT COMPLETE");
        console.log("======================================================================");
        console.log("\nContract Addresses:");
        console.log("  USDC (existing):        ", usdc);
        console.log("  Treasury:               ", address(treasury));
        console.log("  FeeCollector:           ", address(feeCollector));
        console.log("  MockYieldVault:         ", address(vault));
        console.log("  ZybraGroupFactoryV2:    ", address(factory));
        console.log("  ZybraGroupV2:           ", groupAddress);
        console.log("");
    }
}
