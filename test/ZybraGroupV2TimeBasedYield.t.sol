// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import {ZybraGroupV2Refactored} from "src/ZybraGroupV2.sol";
import {ZybraGroupFactoryV2} from "src/ZybraGroupFactoryV2.sol";
import {MockYieldVault} from "src/mocks/MockYieldVault.sol";
import {MockERC20} from "src/mocks/MockERC20.sol";

/**
 * @title ZybraGroupV2TimeBasedYieldTest
 * @notice Test that ZybraGroupV2 sees yield from time-based MockYieldVault after contributions
 */
contract ZybraGroupV2TimeBasedYieldTest is Test {
    ZybraGroupFactoryV2 public factory;
    ZybraGroupV2Refactored public group;
    MockYieldVault public vault;
    MockERC20 public usdc;

    address public admin;
    address public treasury;
    address public alice;
    address public bob;

    uint256 public constant CONTRIBUTION = 100_000_000; // 100 USDC (6 decimals)
    uint256 public constant CYCLE_DURATION = 1 weeks;
    uint256 public constant TOTAL_CYCLES = 4;

    function setUp() public {
        admin = makeAddr("admin");
        treasury = makeAddr("treasury");
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        // Deploy USDC mock
        usdc = new MockERC20("USD Coin", "USDC", 6);

        // Deploy vault with 5% APY
        vm.prank(admin);
        vault = new MockYieldVault(address(usdc), "Mock Yield Vault", "myvUSDC", 6);
        
        // Set higher APY for visible testing (50% = 5000 bps)
        vm.prank(admin);
        vault.setAnnualYieldRate(5000); // 50% APY for fast testing

        // Deploy factory
        factory = new ZybraGroupFactoryV2();

        // Deploy group via factory
        address groupAddress = factory.deployGroup(
            address(usdc),
            CONTRIBUTION,
            CYCLE_DURATION,
            TOTAL_CYCLES,
            admin,
            address(vault),
            treasury
        );
        
        group = ZybraGroupV2Refactored(groupAddress);

        // Mint USDC to users
        usdc.mint(alice, 1_000_000_000); // 1000 USDC
        usdc.mint(bob, 1_000_000_000);

        // Approve group
        vm.prank(alice);
        usdc.approve(address(group), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(group), type(uint256).max);
    }

    function test_YieldAccruesAfterContribution() public {
        console.log("\n=== Test: Yield Accrues After Contribution ===");
        
        // Alice and Bob join
        vm.prank(alice);
        group.joinGroup(alice);
        vm.prank(bob);
        group.joinGroup(bob);

        // Start group
        vm.prank(admin);
        group.startGroup();

        // Alice contributes
        vm.prank(alice);
        group.contribute(alice);
        
        console.log("\nAfter Alice's contribution:");
        (,,,,uint256 totalCapital0, uint256 totalYield0,) = group.getGroupStatus();
        console.log("  Total Capital:", totalCapital0);
        console.log("  Total Yield:", totalYield0);
        assertEq(totalCapital0, CONTRIBUTION, "Capital should equal contribution");
        assertEq(totalYield0, 0, "Yield should be 0 immediately after deposit");

        // Warp 1 day
        vm.warp(block.timestamp + 1 days);
        
        console.log("\nAfter 1 day:");
        (,,,,uint256 totalCapital1, uint256 totalYield1,) = group.getGroupStatus();
        console.log("  Total Capital:", totalCapital1);
        console.log("  Total Yield:", totalYield1);
        assertEq(totalCapital1, CONTRIBUTION, "Capital should remain the same");
        assertGt(totalYield1, 0, "Yield should be > 0 after 1 day");
        
        // Calculate expected yield: 100 USDC * 50% APY * 1/365 days
        uint256 expectedYield = (CONTRIBUTION * 5000 * 1 days) / (10000 * 365 days);
        console.log("  Expected Yield:", expectedYield);
        assertApproxEqRel(totalYield1, expectedYield, 0.01e18, "Yield should match expected");

        // Warp 7 days
        vm.warp(block.timestamp + 6 days);
        
        console.log("\nAfter 7 days total:");
        (,,,,uint256 totalCapital7, uint256 totalYield7,) = group.getGroupStatus();
        console.log("  Total Capital:", totalCapital7);
        console.log("  Total Yield:", totalYield7);
        assertGt(totalYield7, totalYield1, "Yield should increase over time");
        
        uint256 expectedYield7 = (CONTRIBUTION * 5000 * 7 days) / (10000 * 365 days);
        console.log("  Expected Yield:", expectedYield7);
        assertApproxEqRel(totalYield7, expectedYield7, 0.01e18, "Yield should match expected for 7 days");

        console.log("\n[PASS] Yield accrues automatically over time without manual generateYield()");
    }

    function test_YieldIncreasesWithMoreContributions() public {
        console.log("\n=== Test: Yield Increases With More Capital ===");
        
        // Alice and Bob join
        vm.prank(alice);
        group.joinGroup(alice);
        vm.prank(bob);
        group.joinGroup(bob);

        // Start group
        vm.prank(admin);
        group.startGroup();

        // Both contribute in cycle 0
        vm.prank(alice);
        group.contribute(alice);
        
        vm.prank(bob);
        group.contribute(bob);
        
        console.log("\nBoth Alice and Bob contributed 100 USDC each (total 200 USDC)");
        (,,,,uint256 totalCapital,,) = group.getGroupStatus();
        assertEq(totalCapital, CONTRIBUTION * 2, "Capital should be 200 USDC");

        // Warp 1 day
        vm.warp(block.timestamp + 1 days);
        
        (,,,,, uint256 yieldAfter1Day,) = group.getGroupStatus();
        console.log("Yield with 200 USDC after 1 day:", yieldAfter1Day);
        
        // Expected yield for 200 USDC for 1 day at 50% APY
        uint256 expectedYield = (CONTRIBUTION * 2 * 5000 * 1 days) / (10000 * 365 days);
        console.log("Expected yield:", expectedYield);
        
        assertGt(yieldAfter1Day, 0, "Should have positive yield");
        assertApproxEqRel(yieldAfter1Day, expectedYield, 0.01e18, "Yield should match expected");

        console.log("\n[PASS] Yield rate increases proportionally with capital");
    }

    function test_UserCanClaimTimeBasedYield() public {
        console.log("\n=== Test: User Can Claim Time-Based Yield ===");
        
        // Alice and Bob join
        vm.prank(alice);
        group.joinGroup(alice);
        vm.prank(bob);
        group.joinGroup(bob);

        // Start group
        vm.prank(admin);
        group.startGroup();

        // Alice contributes
        vm.prank(alice);
        group.contribute(alice);
        
        // Warp 30 days
        vm.warp(block.timestamp + 30 days);
        
        console.log("\nAfter 30 days:");
        (,,,,, uint256 totalYield,) = group.getGroupStatus();
        console.log("  Total Yield:", totalYield);
        assertGt(totalYield, 0, "Should have yield after 30 days");
        
        // Check Alice's pending yield
        (,uint256 pendingYield,,,) = group.getMemberInfo(alice);
        console.log("  Alice's Pending Yield:", pendingYield);
        assertGt(pendingYield, 0, "Alice should have pending yield");
        
        // Alice claims yield
        uint256 aliceBalanceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        group.claimYield(alice);
        uint256 aliceBalanceAfter = usdc.balanceOf(alice);
        
        uint256 claimed = aliceBalanceAfter - aliceBalanceBefore;
        console.log("  Alice claimed:", claimed);
        assertGt(claimed, 0, "Alice should receive yield tokens");
        assertApproxEqAbs(claimed, pendingYield, 1, "Claimed should match pending yield");

        console.log("\n[PASS] Users can claim time-based yield without manual vault operations");
    }

    function test_SmallAmountStillShowsYield() public {
        console.log("\n=== Test: Even Small Amounts Show Yield ===");
        
        // Deploy new group with small contribution (24 USDC) via factory
        address smallGroupAddress = factory.deployGroup(
            address(usdc),
            24_000_000, // 24 USDC
            CYCLE_DURATION,
            TOTAL_CYCLES,
            admin,
            address(vault),
            treasury
        );
        
        ZybraGroupV2Refactored smallGroup = ZybraGroupV2Refactored(smallGroupAddress);

        vm.prank(alice);
        usdc.approve(address(smallGroup), type(uint256).max);

        vm.prank(alice);
        smallGroup.joinGroup(alice);

        vm.prank(admin);
        smallGroup.startGroup();

        vm.prank(alice);
        smallGroup.contribute(alice);
        
        console.log("\nAlice contributed 24 USDC");
        
        // Warp 1 day
        vm.warp(block.timestamp + 1 days);
        
        (,,,,, uint256 totalYield,) = smallGroup.getGroupStatus();
        console.log("Yield after 1 day:", totalYield);
        assertGt(totalYield, 0, "Even 24 USDC should show yield after 1 day");
        
        // Expected: 24 * 50% * 1/365 = 0.032876 USDC = 32,876 units (6 decimals)
        // Use uint256 cast to avoid fraction issues
        uint256 expected = uint256(24_000_000 * 5000) / uint256(10000 * 365);
        console.log("Expected yield:", expected);
        assertApproxEqRel(totalYield, expected, 0.01e18, "Yield should match calculation");

        console.log("\n[PASS] Small amounts (24 USDC) still show yield > 0");
    }

    // ==================== ACCESS CONTROL SECURITY TESTS ====================

    function test_ContributeRevert_UnauthorizedCaller() public {
        console.log("\n=== Test: contribute() reverts for unauthorized caller ===");

        address attacker = makeAddr("attacker");

        // Alice joins + start group
        vm.prank(alice);
        group.joinGroup(alice);
        vm.prank(admin);
        group.startGroup();

        // Attacker tries to force Alice to contribute
        vm.prank(attacker);
        vm.expectRevert(ZybraGroupV2Refactored.NotAdmin.selector);
        group.contribute(alice);

        console.log("[PASS] Unauthorized contribute reverted");
    }

    function test_ContributeSuccess_AdminOnBehalf() public {
        console.log("\n=== Test: Admin can contribute on behalf of user ===");

        vm.prank(alice);
        group.joinGroup(alice);
        vm.prank(admin);
        group.startGroup();

        // Admin contributes on behalf of Alice (allowed)
        vm.prank(admin);
        group.contribute(alice);

        (,,,,uint256 totalCapital,,) = group.getGroupStatus();
        assertEq(totalCapital, CONTRIBUTION, "Admin contribution on behalf should succeed");
        console.log("[PASS] Admin contribute on behalf works");
    }

    function test_JoinGroupRevert_UnauthorizedCaller() public {
        console.log("\n=== Test: joinGroup() reverts for unauthorized caller ===");

        address attacker = makeAddr("attacker");

        // Attacker tries to add alice to the group
        vm.prank(attacker);
        vm.expectRevert(ZybraGroupV2Refactored.NotAdmin.selector);
        group.joinGroup(alice);

        console.log("[PASS] Unauthorized joinGroup reverted");
    }

    function test_JoinGroupSuccess_AdminOnBehalf() public {
        console.log("\n=== Test: Admin can join users on their behalf ===");

        // Admin adds alice
        vm.prank(admin);
        group.joinGroup(alice);

        assertEq(group.activeMembersCount(), 2, "Should have admin + alice");
        console.log("[PASS] Admin joinGroup on behalf works");
    }

    function test_JoinGroupSuccess_SelfJoin() public {
        console.log("\n=== Test: User can join themselves ===");

        vm.prank(alice);
        group.joinGroup(alice);

        assertEq(group.activeMembersCount(), 2, "Should have admin + alice");
        console.log("[PASS] Self-join works");
    }
}
