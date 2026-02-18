// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/ZybraGroup.sol";
import "../src/ZybraGroupFactory.sol";
import "../src/mocks/MockYieldVault.sol";
import "../src/mocks/MockERC20.sol";

/**
 * @title DeployZybraV2
 * @notice Deploys ZybraGroup ecosystem:
 *         1. MockERC20 (USDC) - for testing
 *         2. MockYieldVault (Mock Morpho Vault)
 *         3. ZybraGroupFactory
 *         4. A sample ZybraGroup via factory
 * 
 * Usage:
 *   Local Anvil: forge script script/DeployZybraV2.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
 *   Sepolia:     forge script script/DeployZybraV2.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast --verify
 */
contract DeployZybraV2 is Script {
    // Deployment parameters
    uint256 constant CONTRIBUTION_AMOUNT = 100e6;  // 100 USDC
    uint256 constant CYCLE_DURATION = 1 weeks;      // 1 week cycles
    uint256 constant TOTAL_CYCLES = 4;              // 4 cycles total

    function run() external {
        // Deployer is the msg.sender when using --sender flag or the private key holder
        address deployer = msg.sender;
        
        console.log("\n");
        console.log("======================================================================");
        console.log("  ZYBRA V2 DEPLOYMENT");
        console.log("======================================================================");
        console.log("\nDeployer:", deployer);
        console.log("Chain ID:", block.chainid);
        console.log("");

        vm.startBroadcast();

        // ============ 1. Deploy Mock USDC ============
        console.log("1. Deploying Mock USDC...");
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        console.log("   MockUSDC deployed at:", address(usdc));

        // ============ 2. Deploy Mock Morpho Vault ============
        console.log("\n2. Deploying Mock Morpho Vault (ERC4626)...");
        MockYieldVault vault = new MockYieldVault(
            address(usdc),
            "Zybra Yield Vault",
            "zUSDC",
            6
        );
        console.log("   MockYieldVault deployed at:", address(vault));

        // ============ 3. Deploy ZybraGroupFactory ============
        console.log("\n3. Deploying ZybraGroupFactory...");
        ZybraGroupFactory factory = new ZybraGroupFactory();
        console.log("   ZybraGroupFactory deployed at:", address(factory));

        // ============ 4. Deploy a Sample ZybraGroup ============
        console.log("\n4. Creating sample ZybraGroup via factory...");
        console.log("   Parameters:");
        console.log("   - Contribution:", CONTRIBUTION_AMOUNT / 1e6, "USDC");
        console.log("   - Cycle Duration:", CYCLE_DURATION / 1 days, "days");
        console.log("   - Total Cycles:", TOTAL_CYCLES);
        console.log("   - Admin:", deployer);
        console.log("   - Vault:", address(vault));

        address groupAddress = factory.deployGroup(
            address(usdc),
            CONTRIBUTION_AMOUNT,
            CYCLE_DURATION,
            TOTAL_CYCLES,
            deployer,
            address(vault),
            deployer  // treasury - using deployer as treasury for testing
        );
        console.log("   ZybraGroup deployed at:", groupAddress);

        // ============ 5. Setup: Mint USDC to deployer ============
        console.log("\n5. Minting 100,000 USDC to deployer for testing...");
        usdc.mint(deployer, 100000e6);
        console.log("   Deployer USDC balance:", usdc.balanceOf(deployer) / 1e6, "USDC");

        // ============ 6. Fund vault for yield generation ============
        console.log("\n6. Funding vault with 1,000,000 USDC for yield generation...");
        usdc.mint(address(vault), 1000000e6);
        console.log("   Vault USDC balance:", usdc.balanceOf(address(vault)) / 1e6, "USDC");

        vm.stopBroadcast();

        // ============ Summary ============
        console.log("\n");
        console.log("======================================================================");
        console.log("  DEPLOYMENT COMPLETE");
        console.log("======================================================================");
        console.log("\nContract Addresses:");
        console.log("  MockUSDC:             ", address(usdc));
        console.log("  MockYieldVault:       ", address(vault));
        console.log("  ZybraGroupFactory:  ", address(factory));
        console.log("  ZybraGroup:         ", groupAddress);
        console.log("\nNext Steps:");
        console.log("  1. Approve USDC for the group: usdc.approve(group, amount)");
        console.log("  2. Join the group: group.joinGroup(userAddress)");
        console.log("  3. Start the group: group.startGroup()");
        console.log("  4. Contribute each cycle: group.contribute(userAddress)");
        console.log("");
    }
}
