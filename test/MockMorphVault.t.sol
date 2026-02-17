// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {MockMorphVault} from "src/mocks/MockMorphVault.sol";
import {MockERC20} from "src/mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title MockMorphVaultTest
 * @notice Comprehensive test suite for MockMorphVault
 * @dev Tests time-based reward generation and vault operations
 */
contract MockMorphVaultTest is Test {
    MockMorphVault public vault;
    MockERC20 public asset;

    address public owner;
    address public alice;
    address public bob;
    address public carol;

    uint256 public constant INITIAL_BALANCE = 1000 ether;
    uint256 public constant WAD = 1e18;

    event UserJoined(address indexed user, uint256 assets, uint256 shares, uint256 timestamp);
    event UserExited(address indexed user, uint256 assets, uint256 shares, uint256 rewards);
    event RewardAccrued(address indexed user, uint256 rewardAmount, uint256 timeElapsed);
    event TotalRewardsDistributed(uint256 totalRewards);

    function setUp() public {
        owner = makeAddr("owner");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        carol = makeAddr("carol");

        // Deploy mock asset token
        asset = new MockERC20("Test Token", "TEST", 18);

        // Deploy vault
        vm.prank(owner);
        vault = new MockMorphVault(
            address(asset),
            "Morph Vault Shares",
            "mvTEST",
            owner
        );

        // Mint initial tokens to users
        asset.mint(alice, INITIAL_BALANCE);
        asset.mint(bob, INITIAL_BALANCE);
        asset.mint(carol, INITIAL_BALANCE);
        asset.mint(owner, INITIAL_BALANCE * 10); // Extra for reward funding

        // Approve vault for all users
        vm.prank(alice);
        asset.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        asset.approve(address(vault), type(uint256).max);
        vm.prank(carol);
        asset.approve(address(vault), type(uint256).max);
        vm.prank(owner);
        asset.approve(address(vault), type(uint256).max);

        // Fund vault with rewards
        vm.prank(owner);
        vault.fundRewards(INITIAL_BALANCE * 5);
    }

    /* BASIC FUNCTIONALITY TESTS */

    function test_Deployment() public {
        assertEq(vault.owner(), owner);
        assertEq(vault.asset(), address(asset));
        assertEq(vault.rewardRate(), 0.1e18); // 10% default APY
        assertEq(vault.totalRewardsDistributed(), 0);
    }

    function test_Deposit() public {
        uint256 depositAmount = 100 ether;

        vm.expectEmit(true, false, false, true);
        emit UserJoined(alice, depositAmount, depositAmount, block.timestamp);

        vm.prank(alice);
        uint256 shares = vault.deposit(depositAmount, alice);

        assertEq(shares, depositAmount);
        assertEq(vault.balanceOf(alice), depositAmount);
        assertEq(vault.totalAssets(), depositAmount);
    }

    function test_Withdraw() public {
        uint256 depositAmount = 100 ether;

        vm.prank(alice);
        vault.deposit(depositAmount, alice);

        vm.prank(alice);
        vault.withdraw(depositAmount, alice, alice);

        assertEq(vault.balanceOf(alice), 0);
        assertEq(asset.balanceOf(alice), INITIAL_BALANCE);
    }

    /* TIME-BASED REWARD TESTS */

    function test_RewardsAccrueOverTime() public {
        uint256 depositAmount = 100 ether;

        vm.prank(alice);
        vault.deposit(depositAmount, alice);

        // Fast forward 365 days (1 year)
        vm.warp(block.timestamp + 365 days);

        uint256 pending = vault.pendingRewards(alice);

        // Should be approximately 10% (10 ether) with 10% APY
        assertApproxEqRel(pending, 10 ether, 0.01e18); // 1% tolerance
    }

    function test_RewardsAccrueProportionalToTime() public {
        uint256 depositAmount = 100 ether;

        vm.prank(alice);
        vault.deposit(depositAmount, alice);

        // Fast forward 182.5 days (half year)
        vm.warp(block.timestamp + 182.5 days);

        uint256 pending = vault.pendingRewards(alice);

        // Should be approximately 5% (5 ether) with 10% APY for half year
        assertApproxEqRel(pending, 5 ether, 0.01e18); // 1% tolerance
    }

    function test_RewardsAccrueForMultipleUsers() public {
        uint256 depositAmount = 100 ether;

        // Alice deposits
        vm.prank(alice);
        vault.deposit(depositAmount, alice);

        // Bob deposits (same amount)
        vm.prank(bob);
        vault.deposit(depositAmount, bob);

        // Fast forward 1 year
        vm.warp(block.timestamp + 365 days);

        uint256 alicePending = vault.pendingRewards(alice);
        uint256 bobPending = vault.pendingRewards(bob);

        // Both should have similar rewards
        assertApproxEqRel(alicePending, 10 ether, 0.01e18);
        assertApproxEqRel(bobPending, 10 ether, 0.01e18);
    }

    function test_EarlyDepositorEarnsMore() public {
        uint256 depositAmount = 100 ether;

        // Alice deposits at day 0
        vm.prank(alice);
        vault.deposit(depositAmount, alice);

        // Fast forward 182.5 days
        vm.warp(block.timestamp + 182.5 days);

        // Bob deposits at day 182.5
        vm.prank(bob);
        vault.deposit(depositAmount, bob);

        // Fast forward another 182.5 days (total 365 days from start)
        vm.warp(block.timestamp + 182.5 days);

        uint256 alicePending = vault.pendingRewards(alice);
        uint256 bobPending = vault.pendingRewards(bob);

        // Alice should have ~10 ether (1 year)
        // Bob should have ~5 ether (half year)
        assertApproxEqRel(alicePending, 10 ether, 0.01e18);
        assertApproxEqRel(bobPending, 5 ether, 0.01e18);
        assertTrue(alicePending > bobPending);
    }

    function test_ClaimRewards() public {
        uint256 depositAmount = 100 ether;

        vm.prank(alice);
        vault.deposit(depositAmount, alice);

        // Fast forward 1 year
        vm.warp(block.timestamp + 365 days);

        uint256 pendingBefore = vault.pendingRewards(alice);
        uint256 balanceBefore = asset.balanceOf(alice);

        vm.expectEmit(true, false, false, false);
        emit TotalRewardsDistributed(pendingBefore);

        vm.prank(alice);
        uint256 claimed = vault.claimRewards();

        assertEq(claimed, pendingBefore);
        assertEq(vault.pendingRewards(alice), 0);
        assertEq(asset.balanceOf(alice), balanceBefore + claimed);
    }

    function test_RewardsResetAfterClaim() public {
        uint256 depositAmount = 100 ether;

        vm.prank(alice);
        vault.deposit(depositAmount, alice);

        // Fast forward 1 year
        vm.warp(block.timestamp + 365 days);

        vm.prank(alice);
        vault.claimRewards();

        // Pending should be 0 right after claim
        assertEq(vault.pendingRewards(alice), 0);

        // Fast forward another year
        vm.warp(block.timestamp + 365 days);

        // Should accrue another year's worth
        uint256 pending = vault.pendingRewards(alice);
        assertApproxEqRel(pending, 10 ether, 0.01e18);
    }

    /* REWARD RATE TESTS */

    function test_SetRewardRate() public {
        uint256 newRate = 0.2e18; // 20% APY

        vm.prank(owner);
        vault.setRewardRate(newRate);

        assertEq(vault.rewardRate(), newRate);
    }

    function test_RewardRateAffectsAccrual() public {
        uint256 depositAmount = 100 ether;

        // Set to 20% APY
        vm.prank(owner);
        vault.setRewardRate(0.2e18);

        vm.prank(alice);
        vault.deposit(depositAmount, alice);

        // Fast forward 1 year
        vm.warp(block.timestamp + 365 days);

        uint256 pending = vault.pendingRewards(alice);

        // Should be approximately 20 ether with 20% APY
        assertApproxEqRel(pending, 20 ether, 0.01e18);
    }

    function test_CannotSetRateTooHigh() public {
        uint256 tooHighRate = 0.6e18; // 60% (max is 50%)

        vm.prank(owner);
        vm.expectRevert(MockMorphVault.RateTooHigh.selector);
        vault.setRewardRate(tooHighRate);
    }

    /* EDGE CASES */

    function test_NoRewardsWithZeroDeposit() public {
        // Alice has no deposit
        assertEq(vault.balanceOf(alice), 0);

        // Fast forward 1 year
        vm.warp(block.timestamp + 365 days);

        assertEq(vault.pendingRewards(alice), 0);
    }

    function test_MultipleDepositsAccrueCorrectly() public {
        // Alice deposits 50 ether
        vm.prank(alice);
        vault.deposit(50 ether, alice);

        // Fast forward 6 months
        vm.warp(block.timestamp + 182.5 days);

        // Alice deposits another 50 ether
        vm.prank(alice);
        vault.deposit(50 ether, alice);

        // Fast forward another 6 months (1 year total)
        vm.warp(block.timestamp + 182.5 days);

        uint256 pending = vault.pendingRewards(alice);

        // First 50 ether for 1 year = 5 ether
        // Second 50 ether for 0.5 year = 2.5 ether
        // Total = 7.5 ether
        assertApproxEqRel(pending, 7.5 ether, 0.02e18); // 2% tolerance
    }

    function test_WithdrawDoesNotClaimRewards() public {
        uint256 depositAmount = 100 ether;

        vm.prank(alice);
        vault.deposit(depositAmount, alice);

        // Fast forward 1 year
        vm.warp(block.timestamp + 365 days);

        uint256 pendingBefore = vault.pendingRewards(alice);

        // Withdraw half
        vm.prank(alice);
        vault.withdraw(50 ether, alice, alice);

        // Pending rewards should still be there
        assertEq(vault.pendingRewards(alice), pendingBefore);
    }

    /* USER INFO TESTS */

    function test_GetUserInfo() public {
        uint256 depositAmount = 100 ether;
        uint256 depositTime = block.timestamp;

        vm.prank(alice);
        vault.deposit(depositAmount, alice);

        MockMorphVault.UserInfo memory info = vault.getUserInfo(alice);

        assertEq(info.depositTimestamp, depositTime);
        assertEq(info.lastRewardUpdate, depositTime);
        assertEq(info.totalDeposited, depositAmount);
        assertEq(info.totalWithdrawn, 0);
    }

    function test_GetTimeInVault() public {
        vm.prank(alice);
        vault.deposit(100 ether, alice);

        // Fast forward 30 days
        vm.warp(block.timestamp + 30 days);

        uint256 timeInVault = vault.getTimeInVault(alice);
        assertEq(timeInVault, 30 days);
    }

    function test_EstimateAnnualYield() public {
        uint256 depositAmount = 100 ether;

        vm.prank(alice);
        vault.deposit(depositAmount, alice);

        uint256 estimatedYield = vault.estimateAnnualYield(alice);

        // Should be 10 ether (10% of 100 ether)
        assertEq(estimatedYield, 10 ether);
    }

    /* FUZZ TESTS */

    function testFuzz_DepositAndWithdraw(uint256 amount) public {
        amount = bound(amount, 1 ether, INITIAL_BALANCE);

        vm.prank(alice);
        vault.deposit(amount, alice);

        assertEq(vault.balanceOf(alice), amount);

        vm.prank(alice);
        vault.withdraw(amount, alice, alice);

        assertEq(vault.balanceOf(alice), 0);
    }

    function testFuzz_RewardsAccrueCorrectly(uint256 amount, uint256 timeElapsed) public {
        amount = bound(amount, 1 ether, INITIAL_BALANCE);
        timeElapsed = bound(timeElapsed, 1 days, 730 days); // 1 day to 2 years

        vm.prank(alice);
        vault.deposit(amount, alice);

        vm.warp(block.timestamp + timeElapsed);

        uint256 pending = vault.pendingRewards(alice);

        // Calculate expected rewards
        uint256 expectedRewards = (amount * vault.rewardRate() * timeElapsed) / (WAD * 365 days);

        assertApproxEqRel(pending, expectedRewards, 0.01e18); // 1% tolerance
    }

    /* OWNERSHIP TESTS */

    function test_OnlyOwnerCanSetRewardRate() public {
        vm.prank(alice);
        vm.expectRevert(MockMorphVault.NotOwner.selector);
        vault.setRewardRate(0.15e18);
    }

    function test_TransferOwnership() public {
        vm.prank(owner);
        vault.transferOwnership(alice);

        assertEq(vault.owner(), alice);

        // Alice can now set reward rate
        vm.prank(alice);
        vault.setRewardRate(0.15e18);
    }

    /* VIEW FUNCTION TESTS */

    function test_CurrentAPY() public {
        assertEq(vault.currentAPY(), 0.1e18); // 10%

        vm.prank(owner);
        vault.setRewardRate(0.15e18);

        assertEq(vault.currentAPY(), 0.15e18); // 15%
    }

    function test_IsSufficientlyFunded() public {
        // Initially should be well funded
        assertTrue(vault.isSufficientlyFunded());

        // Large deposit
        vm.prank(alice);
        vault.deposit(100 ether, alice);

        // Fast forward to accrue rewards
        vm.warp(block.timestamp + 365 days);

        // Should still be funded (we added 5x INITIAL_BALANCE in rewards)
        assertTrue(vault.isSufficientlyFunded());
    }

    function test_GetTotalEarnings() public {
        uint256 depositAmount = 100 ether;

        vm.prank(alice);
        vault.deposit(depositAmount, alice);

        // Fast forward 1 year
        vm.warp(block.timestamp + 365 days);

        // Claim rewards
        vm.prank(alice);
        vault.claimRewards();

        // Fast forward another 6 months
        vm.warp(block.timestamp + 182.5 days);

        uint256 totalEarnings = vault.getTotalEarnings(alice);

        // Should include both claimed (~10 ether) and pending (~5 ether) = ~15 ether
        assertApproxEqRel(totalEarnings, 15 ether, 0.02e18); // 2% tolerance
    }

    /* INTEGRATION TESTS */

    function test_ComplexScenario() public {
        // Alice deposits 100 ether at t=0
        vm.prank(alice);
        vault.deposit(100 ether, alice);

        // Fast forward 90 days
        vm.warp(block.timestamp + 90 days);

        // Bob deposits 200 ether at t=90
        vm.prank(bob);
        vault.deposit(200 ether, bob);

        // Fast forward 90 days (t=180)
        vm.warp(block.timestamp + 90 days);

        // Alice claims rewards
        vm.prank(alice);
        uint256 aliceClaimed1 = vault.claimRewards();

        // Fast forward 90 days (t=270)
        vm.warp(block.timestamp + 90 days);

        // Bob claims rewards
        vm.prank(bob);
        uint256 bobClaimed1 = vault.claimRewards();

        // Fast forward 90 days (t=360)
        vm.warp(block.timestamp + 90 days);

        // Both claim again
        vm.prank(alice);
        uint256 aliceClaimed2 = vault.claimRewards();

        vm.prank(bob);
        uint256 bobClaimed2 = vault.claimRewards();

        // Verify Alice earned more (deposited earlier and for longer)
        uint256 aliceTotal = aliceClaimed1 + aliceClaimed2;
        uint256 bobTotal = bobClaimed1 + bobClaimed2;

        // Alice: 100 ether for ~360 days ≈ 9.86 ether
        // Bob: 200 ether for ~270 days ≈ 14.79 ether
        assertTrue(bobTotal > aliceTotal); // Bob has 2x the deposit
    }
}
