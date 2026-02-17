// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "forge-std/Script.sol";
import "../src/ZybraGroup.sol";
import "../src/ZybraGroupFactory.sol";
import "../src/mocks/MockERC20.sol";
import "../src/mocks/MockERC4626Vault.sol";

contract DeployScript is Script {
    function run() external {
        // Get deployment private key from environment or use default for testing
        uint256 deployerPrivateKey = vm.envOr("PRIVATE_KEY", uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80));

        vm.startBroadcast(deployerPrivateKey);

        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== ZybraGroup Full Deployment ===");
        console.log("");
        console.log("Deploying with account:", deployer);
        console.log("Account balance:", deployer.balance / 1e18, "ETH");
        console.log("");

        // 1. Deploy Mock USDC
        console.log("1. Deploying Mock USDC...");
        MockERC20 mockUSDC = new MockERC20("Mock USDC", "USDC", 6);
        console.log("Mock USDC deployed at:", address(mockUSDC));

        // Mint USDC to deployer (10,000 USDC)
        uint256 mintAmount = 10000e6;
        mockUSDC.mint(deployer, mintAmount);
        console.log("Minted 10,000 USDC to deployer");
        console.log("");

        // 2. Deploy Mock ERC4626 Vault
        console.log("2. Deploying Mock ERC4626 Vault (MetaMorpho)...");
        MockERC4626Vault mockVault = new MockERC4626Vault(
            mockUSDC,
            "Mock Morpho Vault",
            "mvUSDC"
        );
        console.log("Mock Vault deployed at:", address(mockVault));
        console.log("Vault Name:", mockVault.name());
        console.log("Vault Symbol:", mockVault.symbol());
        console.log("");

        // 3. Deploy ZybraGroupFactory
        console.log("3. Deploying ZybraGroupFactory...");
        ZybraGroupFactory factory = new ZybraGroupFactory();
        console.log("ZybraGroupFactory deployed at:", address(factory));
        console.log("");

        // 4. Deploy a test ZybraGroup via factory
        console.log("4. Deploying test ZybraGroup via factory...");
        uint256 contributionAmount = 100e6; // 100 USDC
        uint256 cycleDuration = 1 weeks; // 1 week per cycle
        uint256 totalCycles = 4; // 4 cycles total
        uint256 poolStartTime = block.timestamp + 1 hours; // Start in 1 hour

        address groupAddress = factory.deployGroup(
            address(mockUSDC),
            contributionAmount,
            cycleDuration,
            totalCycles,
            deployer,
            address(mockVault)
        );

        console.log("ZybraGroup deployed at:", groupAddress);
        console.log("Contribution Amount: 100 USDC");
        console.log("Cycle Duration:", cycleDuration, "seconds (1 week)");
        console.log("Total Cycles:", totalCycles);
        console.log("Group Start Time:", poolStartTime);
        console.log("");

        // 5. Get group details
        ZybraGroup group = ZybraGroup(groupAddress);
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

        // 6. Summary
        console.log("=== Deployment Summary ===");
        console.log("Deployer:", deployer);
        console.log("Deployer USDC Balance:", mockUSDC.balanceOf(deployer) / 1e6, "USDC");
        console.log("");
        console.log("=== Contract Addresses ===");
        console.log("Mock USDC:", address(mockUSDC));
        console.log("Mock Vault (MetaMorpho):", address(mockVault));
        console.log("ZybraGroupFactory:", address(factory));
        console.log("Test ZybraGroup:", groupAddress);
        console.log("");

        vm.stopBroadcast();
    }
}
