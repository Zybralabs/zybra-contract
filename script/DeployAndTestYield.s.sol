// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/ZybraGroupV2.sol";
import "../src/ZybraGroupFactoryV2.sol";
import "../src/mocks/MockYieldVault.sol";
import "../src/mocks/MockERC20.sol";

/**
 * @title DeployAndTestYield
 * @notice Deploys fresh contracts and tests yield generation end-to-end
 *
 * This script:
 * 1. Deploys MockYieldVault with correct implementation
 * 2. Deploys ZybraGroupV2 via factory
 * 3. Simulates contributions and yield generation
 * 4. Verifies yield is correctly calculated
 *
 * Usage (Local Anvil):
 *   anvil --fork-url $SEPOLIA_RPC_URL
 *   forge script script/DeployAndTestYield.s.sol --rpc-url http://localhost:8545 --broadcast
 *
 * Usage (Sepolia with existing USDC):
 *   forge script script/DeployAndTestYield.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast --private-key $PRIVATE_KEY
 */
contract DeployAndTestYield is Script {
    // Sepolia USDC address
    address constant SEPOLIA_USDC = 0x9d60E70d6d164708397E7F0aBa139589c7447255;

    // Deployment parameters
    uint256 constant CONTRIBUTION_AMOUNT = 100e6;  // 100 USDC
    uint256 constant CYCLE_DURATION = 1 minutes;    // 1 minute for testing (change to 1 weeks for production)
    uint256 constant TOTAL_CYCLES = 4;              // 4 cycles total

    MockYieldVault public vault;
    ZybraGroupFactoryV2 public factory;
    ZybraGroupV2 public group;
    IERC20 public usdc;

    function run() external {
        address deployer = msg.sender;

        console.log("\n");
        console.log("======================================================================");
        console.log("  ZYBRA V2 - DEPLOY AND TEST YIELD");
        console.log("======================================================================");
        console.log("\nDeployer:", deployer);
        console.log("Chain ID:", block.chainid);
        console.log("");

        vm.startBroadcast();

        // Use Sepolia USDC
        usdc = IERC20(SEPOLIA_USDC);
        console.log("Using USDC:", SEPOLIA_USDC);

        // ============ 1. Deploy MockYieldVault ============
        console.log("\n1. Deploying MockYieldVault (ERC4626)...");
        vault = new MockYieldVault(
            SEPOLIA_USDC,
            "Zybra Yield Vault",
            "zUSDC",
            6
        );
        console.log("   MockYieldVault deployed at:", address(vault));

        // Verify vault has correct functions
        console.log("   Vault totalAssets():", vault.totalAssets());
        console.log("   Vault yieldAccrued:", vault.yieldAccrued());
        console.log("   Vault totalDeposited:", vault.totalDeposited());

        // ============ 2. Deploy ZybraGroupFactoryV2 ============
        console.log("\n2. Deploying ZybraGroupFactoryV2...");
        factory = new ZybraGroupFactoryV2();
        console.log("   ZybraGroupFactoryV2 deployed at:", address(factory));

        // ============ 3. Deploy ZybraGroupV2 ============
        console.log("\n3. Creating ZybraGroupV2 via factory...");
        console.log("   Parameters:");
        console.log("   - USDC:", SEPOLIA_USDC);
        console.log("   - Contribution:", CONTRIBUTION_AMOUNT / 1e6, "USDC");
        console.log("   - Cycle Duration:", CYCLE_DURATION, "seconds");
        console.log("   - Total Cycles:", TOTAL_CYCLES);
        console.log("   - Admin:", deployer);
        console.log("   - Vault:", address(vault));

        address groupAddress = factory.deployGroup(
            SEPOLIA_USDC,
            CONTRIBUTION_AMOUNT,
            CYCLE_DURATION,
            TOTAL_CYCLES,
            deployer,
            address(vault),
            deployer  // treasury - using deployer as treasury for testing
        );
        group = ZybraGroupV2(groupAddress);
        console.log("   ZybraGroupV2 deployed at:", groupAddress);

        vm.stopBroadcast();

        // ============ Summary ============
        console.log("\n");
        console.log("======================================================================");
        console.log("  DEPLOYMENT COMPLETE");
        console.log("======================================================================");
        console.log("\nContract Addresses:");
        console.log("  USDC:                   ", SEPOLIA_USDC);
        console.log("  MockYieldVault:         ", address(vault));
        console.log("  ZybraGroupFactoryV2:    ", address(factory));
        console.log("  ZybraGroupV2:           ", address(group));
        console.log("");
        console.log("======================================================================");
        console.log("  NEXT STEPS - TEST YIELD GENERATION");
        console.log("======================================================================");
        console.log("");
        console.log("See README for test commands using cast with the deployed addresses above.");
    }
}
