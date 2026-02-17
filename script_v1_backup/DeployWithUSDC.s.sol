// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "forge-std/Script.sol";
import "../src/ZybraGroup.sol";
import "../src/mocks/MockERC4626Vault.sol";

/**
 * @title DeployWithUSDC
 * @dev Deployment script for ZybraGroup using existing USDC contract
 *
 * To deploy:
 * forge script script/DeployWithUSDC.s.sol:DeployWithUSDC --rpc-url <RPC_URL> --broadcast --verify
 */
contract DeployWithUSDC is Script {
    // Existing USDC contract address
    address constant USDC = 0x9d60E70d6d164708397E7F0aBa139589c7447255;

    // Deployment parameters - ADJUST THESE AS NEEDED
    uint256 constant CONTRIBUTION_AMOUNT = 100e6; // 100 USDC (6 decimals)
    uint256 constant CYCLE_DURATION = 1 weeks; // 1 week per cycle
    uint256 constant TOTAL_CYCLES = 4; // 4 cycles total

    function run() external {
        // Get deployer private key from environment
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== ZybraGroup Deployment ===");
        console.log("Deployer:", deployer);
        console.log("USDC Address:", USDC);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // Step 1: Deploy Mock Vault (or use existing vault address)
        console.log("1. Deploying Mock ERC4626 Vault...");
        MockERC4626Vault vault = new MockERC4626Vault(
            IERC20(USDC),
            "Zybra Vault USDC",
            "zvUSDC"
        );
        console.log("Mock Vault deployed at:", address(vault));
        console.log("");

        // Step 2: Set pool start time (1 hour from now)
        uint256 poolStartTime = block.timestamp + 1 hours;

        // Step 3: Deploy ZybraGroup
        console.log("2. Deploying ZybraGroup...");
        ZybraGroup group = new ZybraGroup(
            USDC,                    // asset (USDC)
            CONTRIBUTION_AMOUNT,     // contribution amount
            CYCLE_DURATION,          // cycle duration in seconds
            TOTAL_CYCLES,            // total number of cycles
            deployer,                // admin
            address(vault)           // vault address
        );

        console.log("ZybraGroup deployed at:", address(group));
        console.log("");

        // Step 4: Display deployment info
        console.log("=== Deployment Summary ===");
        console.log("USDC Address:", USDC);
        console.log("Vault Address:", address(vault));
        console.log("ZybraGroup Address:", address(group));
        console.log("Admin:", deployer);
        console.log("Contribution Amount:", CONTRIBUTION_AMOUNT / 1e6, "USDC");
        console.log("Cycle Duration:", CYCLE_DURATION / 1 days, "days");
        console.log("Total Cycles:", TOTAL_CYCLES);
        console.log("Group Start Time:", poolStartTime);
        console.log("");

        // Step 5: Get group info
        (
            address groupAdmin,
            address groupAsset,
            uint256 groupContributionAmount,
            uint256 groupCycleDuration,
            uint256 groupTotalCycles,
            uint256 groupCurrentCycle,
            uint256 groupMembersCount,
            bool isPaused,
            bytes32 currentMerkleRoot
        ) = group.getGroupInfo();

        console.log("=== Group Details ===");
        console.log("Admin:", groupAdmin);
        console.log("Asset:", groupAsset);
        console.log("Contribution Amount:", groupContributionAmount / 1e6, "USDC");
        console.log("Cycle Duration:", groupCycleDuration, "seconds");
        console.log("Total Cycles:", groupTotalCycles);
        console.log("Current Cycle:", groupCurrentCycle);
        console.log("Members Count:", groupMembersCount);
        console.log("Is Paused:", isPaused);
        console.log("");

        console.log("=== Next Steps ===");
        console.log("1. Set payout order using setPayoutOrder(merkleRoot)");
        console.log("2. Add members using joinGroup(memberAddress)");
        console.log("3. Start the pool using startGroup() after poolStartTime");
        console.log("");

        vm.stopBroadcast();
    }
}
