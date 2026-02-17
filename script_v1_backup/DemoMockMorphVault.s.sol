// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {MockMorphVault} from "src/mocks/MockMorphVault.sol";
import {MockERC20} from "src/mocks/MockERC20.sol";

/**
 * @title DemoMockMorphVault
 * @notice Interactive demo script showing MockMorphVault functionality
 * @dev Run with: forge script script/DemoMockMorphVault.s.sol -vvvv
 */
contract DemoMockMorphVault is Script {
    MockMorphVault public vault;
    MockERC20 public asset;

    address public alice;
    address public bob;
    address public owner;

    function run() external {
        // Setup addresses
        owner = makeAddr("owner");
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        console.log("==========================================");
        console.log("MockMorphVault Demo");
        console.log("==========================================");
        console.log("Owner:", owner);
        console.log("Alice:", alice);
        console.log("Bob:", bob);
        console.log("==========================================\n");

        // Deploy
        _deploy();

        // Scenario 1: Basic deposit and reward accrual
        console.log("\n--- SCENARIO 1: Basic Deposit and Rewards ---");
        _scenario1_BasicDeposit();

        // Scenario 2: Multiple users at different times
        console.log("\n--- SCENARIO 2: Multiple Users ---");
        _scenario2_MultipleUsers();

        // Scenario 3: Reward claiming
        console.log("\n--- SCENARIO 3: Claiming Rewards ---");
        _scenario3_ClaimRewards();

        // Summary
        _printSummary();
    }

    function _deploy() internal {
        vm.startPrank(owner);

        console.log("Deploying contracts...");

        // Deploy mock USDC
        asset = new MockERC20("Mock USDC", "mUSDC", 6);
        console.log("Mock USDC deployed at:", address(asset));

        // Deploy vault
        vault = new MockMorphVault(
            address(asset),
            "Zybra Morph Vault",
            "zmvUSDC",
            owner
        );
        console.log("Vault deployed at:", address(vault));
        console.log("Default APY:", vault.rewardRate() / 1e16, "%");

        // Mint tokens to users
        asset.mint(alice, 1_000e6);
        asset.mint(bob, 2_000e6);
        asset.mint(owner, 1_000e6);
        console.log("\nTokens minted:");
        console.log("- Alice: 1,000 USDC");
        console.log("- Bob: 2,000 USDC");
        console.log("- Owner: 1,000 USDC");

        // Fund vault with rewards
        asset.approve(address(vault), 100e6);
        vault.fundRewards(100e6);
        console.log("\nVault funded with 100 USDC rewards");
        console.log("Vault sufficiently funded:", vault.isSufficientlyFunded());

        vm.stopPrank();
    }

    function _scenario1_BasicDeposit() internal {
        vm.startPrank(alice);

        uint256 depositAmount = 100e6; // 100 USDC

        // Approve and deposit
        asset.approve(address(vault), depositAmount);
        uint256 shares = vault.deposit(depositAmount, alice);

        console.log("\nAlice deposits:", depositAmount / 1e6, "USDC");
        console.log("Alice receives:", shares / 1e18, "shares (WAD)");
        console.log("Alice's vault balance:", vault.balanceOf(alice) / 1e18, "shares (WAD)");

        // Check initial state
        MockMorphVault.UserInfo memory info = vault.getUserInfo(alice);
        console.log("\nUser Info:");
        console.log("- Deposit timestamp:", info.depositTimestamp);
        console.log("- Total deposited:", info.totalDeposited / 1e6, "USDC");
        console.log("- Pending rewards:", vault.pendingRewards(alice) / 1e6, "USDC");

        // Simulate time passing (30 days)
        vm.warp(block.timestamp + 30 days);
        console.log("\n[30 days later...]");

        uint256 pending = vault.pendingRewards(alice);
        console.log("Pending rewards after 30 days:", pending / 1e4, "/ 100 USDC");
        // Expected: 1000 * 0.1 * (30/365) ≈ 8.22 USDC

        uint256 timeInVault = vault.getTimeInVault(alice);
        console.log("Time in vault:", timeInVault / 1 days, "days");

        vm.stopPrank();
    }

    function _scenario2_MultipleUsers() internal {
        // Bob deposits after Alice
        vm.startPrank(bob);

        uint256 bobDeposit = 200e6; // 200 USDC
        asset.approve(address(vault), bobDeposit);
        vault.deposit(bobDeposit, bob);

        console.log("\nBob deposits:", bobDeposit / 1e6, "USDC");
        console.log("Bob's shares:", vault.balanceOf(bob) / 1e18, "(WAD)");

        vm.stopPrank();

        // Wait another 30 days (60 days total from Alice's deposit, 30 for Bob)
        vm.warp(block.timestamp + 30 days);
        console.log("\n[30 more days pass...]");
        console.log("(60 days since Alice deposited, 30 days since Bob deposited)");

        // Check both users' rewards
        uint256 alicePending = vault.pendingRewards(alice);
        uint256 bobPending = vault.pendingRewards(bob);

        console.log("\nReward Status:");
        console.log("Alice pending:", alicePending / 1e4, "/ 100 USDC");
        // Expected: 1000 * 0.1 * (60/365) ≈ 16.44 USDC

        console.log("Bob pending:", bobPending / 1e4, "/ 100 USDC");
        // Expected: 2000 * 0.1 * (30/365) ≈ 16.44 USDC

        console.log("\nAlice time in vault:", vault.getTimeInVault(alice) / 1 days, "days");
        console.log("Bob time in vault:", vault.getTimeInVault(bob) / 1 days, "days");

        // Show estimated annual yields
        console.log("\nEstimated Annual Yields:");
        console.log("Alice:", vault.estimateAnnualYield(alice) / 1e6, "USDC");
        console.log("Bob:", vault.estimateAnnualYield(bob) / 1e6, "USDC");
    }

    function _scenario3_ClaimRewards() internal {
        // Alice claims rewards
        vm.startPrank(alice);

        uint256 balanceBefore = asset.balanceOf(alice);
        uint256 pendingBefore = vault.pendingRewards(alice);

        console.log("\nAlice claiming rewards...");
        console.log("Pending rewards:", pendingBefore / 1e4, "/ 100 USDC");

        uint256 claimed = vault.claimRewards();

        uint256 balanceAfter = asset.balanceOf(alice);

        console.log("Claimed amount:", claimed / 1e4, "/ 100 USDC");
        console.log("Alice's USDC before:", balanceBefore / 1e6, "USDC");
        console.log("Alice's USDC after:", balanceAfter / 1e6, "USDC");
        console.log("Gain:", (balanceAfter - balanceBefore) / 1e4, "/ 100 USDC");

        // Check pending is now zero
        console.log("\nPending after claim:", vault.pendingRewards(alice) / 1e6, "USDC");

        vm.stopPrank();

        // Wait more time to show rewards continue accruing
        vm.warp(block.timestamp + 30 days);
        console.log("\n[30 more days pass...]");

        uint256 newPending = vault.pendingRewards(alice);
        console.log("New pending rewards:", newPending / 1e4, "/ 100 USDC");
        console.log("(Rewards continue to accrue)");
    }

    function _printSummary() internal view {
        console.log("\n==========================================");
        console.log("FINAL SUMMARY");
        console.log("==========================================");

        console.log("\nVault Statistics:");
        console.log("- Total assets:", vault.totalAssets() / 1e6, "USDC");
        console.log("- Total supply:", vault.totalSupply() / 1e6, "shares");
        console.log("- Total rewards distributed:", vault.totalRewardsDistributed() / 1e4, "/ 100 USDC");
        console.log("- Total accrued rewards:", vault.totalAccruedRewards() / 1e4, "/ 100 USDC");
        console.log("- Current APY:", vault.currentAPY() / 1e16, "%");
        console.log("- Sufficiently funded:", vault.isSufficientlyFunded());

        console.log("\nAlice:");
        console.log("- Shares:", vault.balanceOf(alice) / 1e6);
        console.log("- Assets value:", vault.convertToAssets(vault.balanceOf(alice)) / 1e6, "USDC");
        console.log("- Pending rewards:", vault.pendingRewards(alice) / 1e4, "/ 100 USDC");
        console.log("- Time in vault:", vault.getTimeInVault(alice) / 1 days, "days");
        console.log("- Total earnings:", vault.getTotalEarnings(alice) / 1e4, "/ 100 USDC");

        console.log("\nBob:");
        console.log("- Shares:", vault.balanceOf(bob) / 1e6);
        console.log("- Assets value:", vault.convertToAssets(vault.balanceOf(bob)) / 1e6, "USDC");
        console.log("- Pending rewards:", vault.pendingRewards(bob) / 1e4, "/ 100 USDC");
        console.log("- Time in vault:", vault.getTimeInVault(bob) / 1 days, "days");
        console.log("- Total earnings:", vault.getTotalEarnings(bob) / 1e4, "/ 100 USDC");

        console.log("\n==========================================");
        console.log("Demo Complete!");
        console.log("==========================================");
        console.log("\nKey Takeaways:");
        console.log("1. Rewards accrue based on time in vault");
        console.log("2. Early depositors earn more over time");
        console.log("3. Rewards can be claimed separately from principal");
        console.log("4. Principal is always safe (separate from rewards)");
        console.log("5. Vault tracks all user statistics");
    }
}
