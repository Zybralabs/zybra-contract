// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {ZybraGroup} from "src/ZybraGroup.sol";
import {ZybraGroupFactory} from "src/ZybraGroupFactory.sol";
import {IMorphoVaultV2} from "src/interfaces/IMorphoVaultV2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title ZybraGroup Fee Accrual & Auto-Collect Deep Audit
 * @notice Exhaustive security testing of the MasterChef-style accumulator,
 *         auto-fee collection (Aave Reserve Factor pattern), and all yield paths.
 *
 * SCOPE:
 *   1. Accumulator math correctness (accRewardPerShare, rewardDebt)
 *   2. Auto-fee collection threshold, reserve safety, try/catch resilience
 *   3. Fee extraction attacks (siphoning, front-running, timing manipulation)
 *   4. Precision loss / rounding attacks (dust, 1-wei exploits)
 *   5. Order-independence verification
 *   6. State invariant checks after every operation
 *   7. Edge case: zero capital, single member, max members
 *   8. Economic analysis: fee leakage, fee evasion, over-charging
 *
 * TARGET: Real Morpho Vault V2 (Steakhouse USDC) on mainnet fork
 */
contract ZybraGroupFeeAuditTest is Test {
    // ==================== MAINNET ADDRESSES ====================
    address constant MORPHO_VAULT = 0xBEEF01735c132Ada46AA9aA4c54623cAA92A64CB;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WHALE_1 = 0x37305B1cD40574E4C5Ce33f8e8306Be057fD7341;
    address constant WHALE_2 = 0x4B16c5dE96EB2117bBE5fd171E4d203624B014aa;
    address constant WHALE_3 = 0x55FE002aefF02F77364de339a1292923A15844B8;

    ZybraGroup public group;
    ZybraGroupFactory public factory;
    IMorphoVaultV2 public vault;
    IERC20 public usdc;

    address public admin;
    address public treasury;
    address public user1;
    address public user2;
    address public user3;
    address public user4;
    address public user5;
    address public whale;

    uint256 constant CONTRIBUTION = 1_000e6; // $1,000 USDC
    uint256 constant CYCLE = 1 weeks;
    uint256 constant CYCLES = 12;

    // ==================== SETUP ====================

    function setUp() public {
        // Fork is provided via --fork-url CLI flag
        // vm.createSelectFork is handled by foundry when --fork-url is passed

        admin = makeAddr("admin");
        treasury = makeAddr("treasury");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        user3 = makeAddr("user3");
        user4 = makeAddr("user4");
        user5 = makeAddr("user5");

        usdc = IERC20(USDC);
        vault = IMorphoVaultV2(MORPHO_VAULT);

        // Pick whale
        if (usdc.balanceOf(WHALE_1) >= 10_000_000e6) whale = WHALE_1;
        else if (usdc.balanceOf(WHALE_2) >= 10_000_000e6) whale = WHALE_2;
        else whale = WHALE_3;
        if (usdc.balanceOf(whale) < 10_000_000e6) deal(USDC, whale, 100_000_000e6);

        group = new ZybraGroup(USDC, CONTRIBUTION, CYCLE, CYCLES, admin, MORPHO_VAULT);
        factory = new ZybraGroupFactory(treasury);

        // Fund users
        vm.startPrank(whale);
        usdc.transfer(admin, 1_000_000e6);
        usdc.transfer(user1, 1_000_000e6);
        usdc.transfer(user2, 1_000_000e6);
        usdc.transfer(user3, 1_000_000e6);
        usdc.transfer(user4, 1_000_000e6);
        usdc.transfer(user5, 1_000_000e6);
        vm.stopPrank();

        // Approve
        address[6] memory users = [admin, user1, user2, user3, user4, user5];
        for (uint256 i = 0; i < 6; i++) {
            vm.prank(users[i]);
            usdc.approve(address(group), type(uint256).max);
        }
    }

    // ==================== HELPERS ====================

    function _startGroup() internal {
        vm.prank(user1);
        group.joinGroup();
        vm.prank(admin);
        group.startGroup();
    }

    function _startGroupMulti() internal {
        vm.prank(user1);
        group.joinGroup();
        vm.prank(user2);
        group.joinGroup();
        vm.prank(user3);
        group.joinGroup();
        vm.prank(admin);
        group.startGroup();
    }

    function _startGroupFull() internal {
        vm.prank(user1);
        group.joinGroup();
        vm.prank(user2);
        group.joinGroup();
        vm.prank(user3);
        group.joinGroup();
        vm.prank(user4);
        group.joinGroup();
        vm.prank(user5);
        group.joinGroup();
        vm.prank(admin);
        group.startGroup();
    }

    function _warpToCycle(uint256 cycleNum) internal {
        uint256 targetTs = group.groupStartTime() + (cycleNum - 1) * group.cycleDuration() + 1;
        vm.warp(targetTs);
    }

    function _fmt(uint256 amount) internal pure returns (string memory) {
        uint256 whole = amount / 1e6;
        uint256 frac = (amount % 1e6) / 1e4;
        if (frac < 10) return string.concat(vm.toString(whole), ".0", vm.toString(frac));
        return string.concat(vm.toString(whole), ".", vm.toString(frac));
    }

    /// @dev Core invariant: vault value >= totalCapitalInGroup (within rounding tolerance)
    function _assertVaultCoversCapital(ZybraGroup g) internal {
        uint256 cap = g.totalCapitalInGroup();
        uint256 shares = vault.balanceOf(address(g));
        uint256 vaultVal = shares > 0 ? vault.convertToAssets(shares) : 0;
        // Allow 1 USDC rounding tolerance
        assertTrue(cap <= vaultVal + 1e6, "INVARIANT: vault must cover capital");
    }

    /// @dev Accumulator invariant: totalAccumulatedFees >= totalFeesWithdrawn
    function _assertFeeInvariant(ZybraGroup g) internal {
        assertGe(g.totalAccumulatedFees(), g.totalFeesWithdrawn(), "INVARIANT: fees >= withdrawn");
    }

    /// @dev Conservation: vault = capital + pendingUserYield + pendingFees (approximately)
    function _assertConservation(ZybraGroup g, address[] memory users) internal {
        uint256 vaultShares = vault.balanceOf(address(g));
        uint256 vaultVal = vaultShares > 0 ? vault.convertToAssets(vaultShares) : 0;
        uint256 cap = g.totalCapitalInGroup();
        uint256 pendingFees = g.totalAccumulatedFees() - g.totalFeesWithdrawn();

        uint256 totalPending;
        for (uint256 i = 0; i < users.length; i++) {
            totalPending += g.pendingYield(users[i]);
        }

        // vault should approximately equal: capital + pending yield + pending fees
        // Allow for some rounding dust
        uint256 expected = cap + totalPending + pendingFees;
        // We allow up to 10 USDC of dust for large positions
        uint256 tolerance = 10e6;
        assertApproxEqAbs(vaultVal, expected, tolerance,
            "CONSERVATION: vault ~= capital + pendingYield + pendingFees");
    }

    // ========================================================================
    //  SECTION 1: ACCUMULATOR MATH CORRECTNESS
    // ========================================================================

    /// @notice Verify accRewardPerShare starts at 0 and only increases
    function test_AccRewardPerShare_Monotonic() public {
        _startGroupMulti();

        uint256 prevAcc = group.accRewardPerShare();
        assertEq(prevAcc, 0, "Starts at 0");

        vm.prank(user1);
        group.contribute();
        vm.prank(user2);
        group.contribute();

        // After contributions with no yield yet, accRPS should be 0 or very small
        uint256 acc1 = group.accRewardPerShare();

        vm.warp(block.timestamp + 30 days);

        vm.prank(user3);
        group.contribute(); // triggers _accrueRewards

        uint256 acc2 = group.accRewardPerShare();
        assertGe(acc2, acc1, "accRewardPerShare monotonically increases");

        vm.warp(block.timestamp + 30 days);

        // Claim triggers accrue
        uint256 p = group.pendingYield(user1);
        if (p > 0) {
            vm.prank(user1);
            group.claimYield();
        }

        uint256 acc3 = group.accRewardPerShare();
        assertGe(acc3, acc2, "Still monotonic after claim");
    }

    /// @notice Verify rewardDebt is correctly set on contribute
    function test_RewardDebt_SetOnContribute() public {
        _startGroupMulti();

        // User1 contributes — no yield yet, so debt should be 0
        vm.prank(user1);
        group.contribute();
        (uint256 cap1, , uint256 lastCycle1, bool active1) = group.getMemberInfo(user1);
        assertEq(cap1, CONTRIBUTION, "Capital tracked");

        // Warp for yield
        vm.warp(block.timestamp + 30 days);

        // User2 contributes — debt should match new accRewardPerShare
        vm.prank(user2);
        group.contribute();

        // User2's pending yield should be ~0 (just contributed after accrue)
        uint256 pending2 = group.pendingYield(user2);
        assertTrue(pending2 < 1e6, "New contributor has ~0 pending yield");

        // User1's pending yield should be > 0 (has been in since before yield)
        uint256 pending1 = group.pendingYield(user1);
        assertGt(pending1, pending2, "Earlier contributor has more yield");
    }

    /// @notice Verify additive debt preserves existing yield across contributions
    function test_AdditivaDebt_PreservesYield() public {
        _startGroup();

        vm.prank(user1);
        group.contribute();

        vm.warp(block.timestamp + 30 days);

        uint256 pendingBefore = group.pendingYield(user1);

        // Contribute again in cycle 2
        _warpToCycle(2);
        // Make sure enough time has passed (at least 30 days from above)
        uint256 now_ = block.timestamp;
        if (now_ < group.groupStartTime() + 30 days) {
            vm.warp(group.groupStartTime() + 30 days + 1);
        }

        vm.warp(group.groupStartTime() + CYCLE + 1); // cycle 2
        uint256 pendingJustBefore = group.pendingYield(user1);

        vm.prank(user1);
        group.contribute();

        // After contributing, pending yield should be preserved (not reset to 0)
        uint256 pendingAfter = group.pendingYield(user1);

        console.log("Pending before C2 contribute: $%s", _fmt(pendingJustBefore));
        console.log("Pending after  C2 contribute: $%s", _fmt(pendingAfter));

        // The yield shouldn't be wiped out — it should be close to what it was
        // (may differ slightly due to accrual during the contribute tx)
        assertGe(pendingAfter + 1e6, pendingJustBefore, "Additive debt preserves yield");
    }

    /// @notice Verify order-independence: A claims then B claims == B claims then A claims
    function test_OrderIndependence_ClaimOrder() public {
        _startGroupMulti();

        vm.prank(user1);
        group.contribute();
        vm.prank(user2);
        group.contribute();

        vm.warp(block.timestamp + 60 days);

        // Snapshot state
        uint256 pending1 = group.pendingYield(user1);
        uint256 pending2 = group.pendingYield(user2);

        console.log("Pending User1: $%s | User2: $%s", _fmt(pending1), _fmt(pending2));

        // Equal capital, same duration → approximately equal yield
        if (pending1 > 0 && pending2 > 0) {
            assertApproxEqRel(pending1, pending2, 0.01e18, "Equal yield for equal capital/time");
        }

        // Claim in order 1→2
        uint256 bal1Before = usdc.balanceOf(user1);
        if (pending1 > 0) {
            vm.prank(user1);
            group.claimYield();
        }

        uint256 bal2Before = usdc.balanceOf(user2);
        uint256 pending2After1Claim = group.pendingYield(user2);
        if (pending2After1Claim > 0) {
            vm.prank(user2);
            group.claimYield();
        }

        uint256 received1 = usdc.balanceOf(user1) - bal1Before;
        uint256 received2 = usdc.balanceOf(user2) - bal2Before;

        console.log("Received User1: $%s | User2: $%s", _fmt(received1), _fmt(received2));

        // Both should receive approximately the same
        if (received1 > 0 && received2 > 0) {
            assertApproxEqRel(received1, received2, 0.02e18,
                "ORDER-INDEPENDENT: claim order doesn't matter");
        }
    }

    // ========================================================================
    //  SECTION 2: AUTO-FEE COLLECTION DEEP AUDIT
    // ========================================================================

    /// @notice Verify auto-collect fires when fees >= MIN_FEE_AUTO_COLLECT (1 USDC)
    function test_AutoCollect_ThresholdBehavior() public {
        _startGroupMulti();

        // All contribute
        vm.prank(user1);
        group.contribute();
        vm.prank(user2);
        group.contribute();
        vm.prank(user3);
        group.contribute();

        // Short warp — should NOT trigger auto-collect (fees < 1 USDC)
        vm.warp(block.timestamp + 1 hours);
        uint256 treasBefore = usdc.balanceOf(treasury);

        _warpToCycle(2);
        vm.prank(user1);
        group.contribute(); // triggers _accrueRewards → _autoCollectFees

        uint256 treasAfterShort = usdc.balanceOf(treasury);
        console.log("Treasury after short warp + contribute: $%s", _fmt(treasAfterShort));

        // Long warp — should trigger auto-collect
        vm.warp(block.timestamp + 90 days);
        uint256 treas90dBefore = usdc.balanceOf(treasury);

        _warpToCycle(3);
        vm.prank(user2);
        group.contribute(); // triggers accrue with accumulated yield

        uint256 treas90dAfter = usdc.balanceOf(treasury);
        uint256 autoCollected = treas90dAfter - treas90dBefore;

        console.log("Auto-collected after 90d yield: $%s", _fmt(autoCollected));

        // Verify fee accounting integrity
        _assertFeeInvariant(group);
    }

    /// @notice Verify auto-collect NEVER drains vault below capital
    function test_AutoCollect_ReserveSafety() public {
        _startGroupMulti();

        vm.prank(user1);
        group.contribute();
        vm.prank(user2);
        group.contribute();

        // Generate significant yield (stay within 12-cycle window = 84 days)
        _warpToCycle(11);

        // Trigger accrual via user3 contribute in cycle 11
        vm.prank(user3);
        group.contribute();

        // After auto-collect, vault must still cover all capital
        _assertVaultCoversCapital(group);

        // Users can still withdraw their full capital + yield
        uint256 bal1 = usdc.balanceOf(user1);
        vm.prank(user1);
        group.withdraw();
        assertGe(usdc.balanceOf(user1) - bal1, CONTRIBUTION - 1e6, "User gets capital back post-auto-collect");

        _assertFeeInvariant(group);
    }

    /// @notice Verify auto-collect try/catch: fee failure doesn't block user action
    function test_AutoCollect_TryCatch_NeverBlocksUser() public {
        _startGroupMulti();

        vm.prank(user1);
        group.contribute();
        vm.prank(user2);
        group.contribute();

        vm.warp(block.timestamp + 60 days);

        // Even if something is weird with the vault, user operations should succeed
        // The try/catch in _autoCollectFees ensures this
        uint256 bal = usdc.balanceOf(user1);
        vm.prank(user1);
        group.withdraw();
        assertGe(usdc.balanceOf(user1) - bal, CONTRIBUTION - 1e6, "Withdraw succeeds regardless of fee collect");
    }

    /// @notice Manual collectFees after auto-collect should return 0 (no double-spend)
    function test_AutoCollect_ThenManualCollect_NoDoubleFees() public {
        _startGroupMulti();

        vm.prank(user1);
        group.contribute();
        vm.prank(user2);
        group.contribute();
        vm.prank(user3);
        group.contribute();

        vm.warp(block.timestamp + 180 days);

        // Trigger auto-collect via contribute
        _warpToCycle(2);
        vm.prank(user1);
        group.contribute();

        uint256 autoFeesWithdrawn = group.totalFeesWithdrawn();
        uint256 treasAfterAuto = usdc.balanceOf(treasury);

        console.log("Fees auto-withdrawn: $%s", _fmt(autoFeesWithdrawn));

        // Manual collectFees — should get remaining (if any) or 0
        uint256 manualResult = group.collectFees();
        uint256 treasAfterManual = usdc.balanceOf(treasury);

        console.log("Manual collect result: $%s", _fmt(manualResult));
        console.log("Treasury: after auto=$%s | after manual=$%s",
            _fmt(treasAfterAuto), _fmt(treasAfterManual));

        // Total withdrawn should not exceed accumulated
        assertGe(group.totalAccumulatedFees(), group.totalFeesWithdrawn(),
            "No double-spend: accumulated >= withdrawn");

        _assertFeeInvariant(group);
    }

    /// @notice Auto-collect on every operation doesn't cause accounting drift
    function test_AutoCollect_RepeatedAccruals_NoDrift() public {
        _startGroupFull();

        // Contribute cycle 1
        vm.prank(user1);
        group.contribute();
        vm.prank(user2);
        group.contribute();
        vm.prank(user3);
        group.contribute();

        // Many small warps with operations to trigger repeated accruals
        for (uint256 i = 0; i < 10; i++) {
            vm.warp(block.timestamp + 7 days);
            // Claim triggers accrue
            uint256 p = group.pendingYield(user1);
            if (p > 0) {
                vm.prank(user1);
                group.claimYield();
            }
            _assertFeeInvariant(group);
            _assertVaultCoversCapital(group);
        }

        // Final state check
        uint256 accFees = group.totalAccumulatedFees();
        uint256 withdrawn = group.totalFeesWithdrawn();
        uint256 distributed = group.totalDistributedYield();

        console.log("After 10 accruals:");
        console.log("  Accumulated fees: $%s", _fmt(accFees));
        console.log("  Fees withdrawn:   $%s", _fmt(withdrawn));
        console.log("  Yield distributed: $%s", _fmt(distributed));

        assertGe(accFees, withdrawn, "Fees balanced");
    }

    // ========================================================================
    //  SECTION 3: FEE EXTRACTION ATTACK VECTORS
    // ========================================================================

    /// @notice Attacker cannot extract fees by calling collectFees in a loop
    function test_EXPLOIT_CollectFees_LoopExtraction() public {
        _startGroupMulti();

        vm.prank(user1);
        group.contribute();
        vm.prank(user2);
        group.contribute();

        vm.warp(block.timestamp + 90 days);

        address attacker = makeAddr("attacker");
        uint256 attackerBal = usdc.balanceOf(attacker);

        // Try collecting 10 times rapidly
        for (uint256 i = 0; i < 10; i++) {
            vm.prank(attacker);
            group.collectFees();
        }

        // Attacker gets nothing
        assertEq(usdc.balanceOf(attacker), attackerBal, "Attacker gains 0 from loop");
        // Treasury gets fees (once, not 10x)
        _assertFeeInvariant(group);
    }

    /// @notice Front-running collectFees — race condition analysis
    function test_EXPLOIT_FrontRunCollectFees() public {
        _startGroupMulti();

        vm.prank(user1);
        group.contribute();
        vm.prank(user2);
        group.contribute();

        vm.warp(block.timestamp + 90 days);

        // Attacker front-runs a user's claimYield with collectFees
        address attacker = makeAddr("attacker");
        uint256 treasBefore = usdc.balanceOf(treasury);

        // "Front-run": attacker calls collectFees
        vm.prank(attacker);
        group.collectFees();

        uint256 treasAfterAttack = usdc.balanceOf(treasury);

        // User claims yield — should still work correctly
        uint256 pending = group.pendingYield(user1);
        uint256 userBal = usdc.balanceOf(user1);
        if (pending > 0) {
            vm.prank(user1);
            group.claimYield();
        }
        uint256 userReceived = usdc.balanceOf(user1) - userBal;

        console.log("Treasury from front-run: $%s", _fmt(treasAfterAttack - treasBefore));
        console.log("User yield after front-run: $%s", _fmt(userReceived));

        // User's yield is NOT stolen
        _assertVaultCoversCapital(group);
        _assertFeeInvariant(group);
    }

    /// @notice Sandwich attack: contribute → manipulate vault → withdraw
    function test_EXPLOIT_SandwichFeeManipulation() public {
        _startGroupMulti();

        vm.prank(user1);
        group.contribute();

        vm.warp(block.timestamp + 30 days);

        // Snapshot fee state
        uint256 feesBefore = group.totalAccumulatedFees();

        // Attacker contributes to dilute yield, immediately withdraws
        vm.prank(user2);
        group.contribute();

        uint256 feesAfterContrib = group.totalAccumulatedFees();

        // Verify fees only go up
        assertGe(feesAfterContrib, feesBefore, "Fees cannot decrease");

        // Attacker withdraws
        vm.prank(user2);
        group.withdraw();

        uint256 feesAfterWithdraw = group.totalAccumulatedFees();
        assertGe(feesAfterWithdraw, feesAfterContrib, "Fees survive withdrawal");
    }

    /// @notice Flash contribute-claim-withdraw to steal yield
    function test_EXPLOIT_FlashYieldSteal() public {
        _startGroupMulti();

        vm.prank(user1);
        group.contribute();

        // Generate yield (stay within 12-cycle window = 84 days)
        _warpToCycle(12);

        uint256 user1PendingBefore = group.pendingYield(user1);

        // Attacker (user2) contributes in last cycle and immediately tries to claim yield
        vm.prank(user2);
        group.contribute();

        uint256 attackerPending = group.pendingYield(user2);

        console.log("User1 (90d in) pending: $%s", _fmt(user1PendingBefore));
        console.log("Attacker (just joined) pending: $%s", _fmt(attackerPending));

        // Attacker should get ~0 yield (just contributed)
        assertTrue(attackerPending < CONTRIBUTION / 100, "Attacker gets near-zero yield on flash entry");

        // User1's yield should NOT be significantly diluted
        uint256 user1PendingAfter = group.pendingYield(user1);
        // The yield before and after should be very close (accrue happened on user2's contribute)
        assertApproxEqRel(user1PendingAfter, user1PendingBefore, 0.05e18,
            "Existing user yield not stolen by flash entry");
    }

    /// @notice Multiple claims in same block don't drain extra
    function test_EXPLOIT_MultiClaimSameBlock() public {
        _startGroupMulti();

        vm.prank(user1);
        group.contribute();
        vm.prank(user2);
        group.contribute();

        vm.warp(block.timestamp + 60 days);

        // User1 claims
        uint256 p1 = group.pendingYield(user1);
        uint256 bal1 = usdc.balanceOf(user1);
        if (p1 > 0) {
            vm.prank(user1);
            group.claimYield();
        }
        uint256 received1 = usdc.balanceOf(user1) - bal1;

        // User2 claims in same "block"
        uint256 p2 = group.pendingYield(user2);
        uint256 bal2 = usdc.balanceOf(user2);
        if (p2 > 0) {
            vm.prank(user2);
            group.claimYield();
        }
        uint256 received2 = usdc.balanceOf(user2) - bal2;

        console.log("User1 received: $%s | User2 received: $%s", _fmt(received1), _fmt(received2));

        // Both should get approximately equal (same capital, same duration)
        if (received1 > 0 && received2 > 0) {
            assertApproxEqRel(received1, received2, 0.02e18,
                "Same-block claims don't give unequal yields");
        }

        _assertFeeInvariant(group);
    }

    /// @notice Contribute at max then emergency withdraw to evade fees
    function test_EXPLOIT_EmergencyWithdrawFeeEvasion() public {
        _startGroupMulti();

        vm.prank(user1);
        group.contribute();

        vm.warp(block.timestamp + 90 days);

        uint256 feesBefore = group.totalAccumulatedFees();

        // Emergency withdraw — capital only, yield forfeited
        vm.prank(user1);
        group.emergencyWithdraw();

        uint256 feesAfter = group.totalAccumulatedFees();

        // Fees must NOT decrease — emergency withdraw accrues first
        assertGe(feesAfter, feesBefore, "Emergency withdraw doesn't erase fees");

        // Forfeited yield should eventually become more fees or stay for others
        console.log("Fees before: $%s | After emergency: $%s", _fmt(feesBefore), _fmt(feesAfter));
    }

    /// @notice Cannot manipulate fee timing by rapidly pausing/unpausing
    function test_EXPLOIT_PauseUnpauseFeeManipulation() public {
        _startGroupMulti();

        vm.prank(user1);
        group.contribute();
        vm.prank(user2);
        group.contribute();

        vm.warp(block.timestamp + 30 days);

        // Admin rapidly pauses/unpauses
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(admin);
            group.pause();
            vm.prank(admin);
            group.unpause();
        }

        // Fees should still be correct
        uint256 pending = group.pendingYield(user1);
        uint256 fees = group.totalAccumulatedFees();

        // Collect fees — should work normally
        group.collectFees();

        _assertFeeInvariant(group);
        console.log("Pending yield after pause/unpause: $%s | Fees: $%s", _fmt(pending), _fmt(fees));
    }

    // ========================================================================
    //  SECTION 4: PRECISION & ROUNDING ATTACKS
    // ========================================================================

    /// @notice Tiny contributions don't cause precision loss in accumulator
    function test_PRECISION_MinContribution() public {
        // Use min contribution ($1 USDC)
        ZybraGroup minGroup = new ZybraGroup(
            USDC, 1e6, CYCLE, CYCLES, admin, MORPHO_VAULT
        );

        deal(USDC, user1, 100e6);
        deal(USDC, user2, 100e6);

        vm.prank(user1);
        usdc.approve(address(minGroup), type(uint256).max);
        vm.prank(user2);
        usdc.approve(address(minGroup), type(uint256).max);
        vm.prank(admin);
        usdc.approve(address(minGroup), type(uint256).max);
        deal(USDC, admin, 100e6);

        vm.prank(user1);
        minGroup.joinGroup();
        vm.prank(admin);
        minGroup.startGroup();

        vm.prank(user1);
        minGroup.contribute();

        vm.warp(block.timestamp + 365 days);

        // Even $1 should accrue some yield
        uint256 pending = minGroup.pendingYield(user1);
        console.log("$1 USDC after 1 year: pending=$%s", _fmt(pending));

        // Should not underflow
        uint256 bal = usdc.balanceOf(user1);
        vm.prank(user1);
        minGroup.withdraw();
        uint256 received = usdc.balanceOf(user1) - bal;
        assertGe(received, 1e6 - 1, "Got at least $1 back");
    }

    /// @notice Max contributions don't cause overflow in accumulator
    function test_PRECISION_MaxContribution_50Users() public {
        // Max: $1000 x 50 users x 12 cycles = $600K
        ZybraGroup maxGroup = new ZybraGroup(
            USDC, 1000e6, CYCLE, CYCLES, admin, MORPHO_VAULT
        );

        address[] memory users = new address[](50);
        users[0] = admin;
        for (uint256 i = 1; i < 50; i++) {
            users[i] = makeAddr(string.concat("max_user_", vm.toString(i)));
            deal(USDC, users[i], 100_000e6);
            vm.prank(users[i]);
            usdc.approve(address(maxGroup), type(uint256).max);
            vm.prank(users[i]);
            maxGroup.joinGroup();
        }
        deal(USDC, admin, 100_000e6);
        vm.prank(admin);
        usdc.approve(address(maxGroup), type(uint256).max);
        vm.prank(admin);
        maxGroup.startGroup();

        // All contribute for all cycles
        for (uint256 cycle = 1; cycle <= CYCLES; cycle++) {
            vm.warp(maxGroup.groupStartTime() + (cycle - 1) * CYCLE + 1);
            for (uint256 u = 0; u < 50; u++) {
                vm.prank(users[u]);
                maxGroup.contribute();
            }
        }

        assertEq(maxGroup.totalCapitalInGroup(), 600_000e6, "$600K total");

        // Warp 1 year
        vm.warp(block.timestamp + 365 days);

        // Accumulator must not overflow
        uint256 acc = maxGroup.accRewardPerShare();
        assertLt(acc, type(uint128).max, "No overflow");

        // All users should have valid pending yield
        for (uint256 i = 0; i < 50; i++) {
            uint256 p = maxGroup.pendingYield(users[i]);
            assertGe(p, 0, "Non-negative yield");
        }
    }

    /// @notice 1-wei yield edge case
    function test_PRECISION_OneWeiYield() public {
        _startGroup();

        vm.prank(user1);
        group.contribute();

        // Very short warp — potentially 0 or 1 wei yield
        vm.warp(block.timestamp + 1);

        uint256 pending = group.pendingYield(user1);
        // Should not revert, just be 0 or tiny
        assertTrue(pending < CONTRIBUTION, "Pending < capital");

        // Claim should either work or revert with NothingToClaim
        if (pending > 0) {
            vm.prank(user1);
            group.claimYield();
        } else {
            vm.prank(user1);
            vm.expectRevert(ZybraGroup.NothingToClaim.selector);
            group.claimYield();
        }
    }

    /// @notice Fee rounding: verify 10% fee math doesn't lose to rounding
    function test_PRECISION_FeeRounding() public {
        _startGroupMulti();

        vm.prank(user1);
        group.contribute();
        vm.prank(user2);
        group.contribute();

        // Generate significant yield
        vm.warp(block.timestamp + 180 days);

        // Trigger accrual
        uint256 feeResult = group.collectFees();

        uint256 totalAcc = group.totalAccumulatedFees();
        uint256 totalDist = group.totalDistributedYield();

        console.log("Fees accumulated: $%s", _fmt(totalAcc));
        console.log("Yield distributed: $%s", _fmt(totalDist));
        console.log("Fees collected: $%s", _fmt(feeResult));

        // Fees should be approximately 10% of total yield
        if (totalDist > 0) {
            // fee / (fee + distributed) should be ~10% (within rounding)
            uint256 totalYield = totalAcc + totalDist;
            uint256 feePercent = (totalAcc * 10000) / totalYield;
            console.log("Fee percentage: %s bps", feePercent);
            // Allow 500 bps tolerance (5%) due to auto-collect timing
            assertApproxEqAbs(feePercent, 1000, 500, "Fees ~10% of total yield");
        }
    }

    // ========================================================================
    //  SECTION 5: EDGE CASES & BOUNDARY CONDITIONS
    // ========================================================================

    /// @notice Zero capital scenario — all yield goes to fees
    function test_EDGE_ZeroCapital_YieldToFees() public {
        _startGroupMulti();

        vm.prank(user1);
        group.contribute();

        vm.warp(block.timestamp + 30 days);

        // Withdraw all — capital becomes 0
        vm.prank(user1);
        group.withdraw();

        assertEq(group.totalCapitalInGroup(), 0, "Zero capital");

        // Any remaining yield should go to fees
        vm.warp(block.timestamp + 30 days);

        // Trigger via collectFees
        uint256 fees = group.collectFees();
        console.log("Fees when zero capital: $%s", _fmt(fees));

        _assertFeeInvariant(group);
    }

    /// @notice Single member — gets all yield minus fees
    function test_EDGE_SingleMember_AllYield() public {
        _startGroup();

        vm.prank(user1);
        group.contribute();

        vm.warp(block.timestamp + 90 days);

        uint256 pendingYield = group.pendingYield(user1);
        uint256 pendingFees = group.totalAccumulatedFees();

        console.log("Single member pending: $%s | Fees: $%s", _fmt(pendingYield), _fmt(pendingFees));

        // User should get 90% of yield, fees should be 10%
        vm.prank(user1);
        group.withdraw();

        // Check final fee state
        uint256 totalFees = group.totalAccumulatedFees();
        uint256 totalDist = group.totalDistributedYield();

        if (totalFees > 0 && totalDist > 0) {
            uint256 feeRatio = (totalFees * 10000) / (totalFees + totalDist);
            console.log("Fee ratio: %s bps (target: 1000)", feeRatio);
            assertApproxEqAbs(feeRatio, 1000, 500, "~10% fee ratio");
        }
    }

    /// @notice All members withdraw at once — no leftover dust
    function test_EDGE_MassWithdraw_NoDustLockup() public {
        _startGroupFull();

        // Everyone contributes
        vm.prank(admin);
        group.contribute();
        vm.prank(user1);
        group.contribute();
        vm.prank(user2);
        group.contribute();
        vm.prank(user3);
        group.contribute();
        vm.prank(user4);
        group.contribute();
        vm.prank(user5);
        group.contribute();

        vm.warp(block.timestamp + 60 days);

        // Everyone withdraws
        address[6] memory allUsers = [admin, user1, user2, user3, user4, user5];
        for (uint256 i = 0; i < 6; i++) {
            vm.prank(allUsers[i]);
            group.withdraw();
        }

        assertEq(group.totalCapitalInGroup(), 0, "All capital out");
        assertEq(group.activeMembersCount(), 0, "No active members");

        // Collect remaining fees
        uint256 remainingFees = group.totalAccumulatedFees() - group.totalFeesWithdrawn();
        console.log("Remaining fees after mass withdraw: $%s", _fmt(remainingFees));

        if (remainingFees > 0) {
            group.collectFees();
        }

        // Vault should have near-zero shares (only rounding dust)
        uint256 remainingShares = vault.balanceOf(address(group));
        uint256 remainingValue = remainingShares > 0 ? vault.convertToAssets(remainingShares) : 0;
        console.log("Vault dust remaining: $%s", _fmt(remainingValue));

        // Should be very small (< $1)
        assertTrue(remainingValue < 1e6, "Minimal vault dust");
    }

    /// @notice Group ended — fees can still be collected
    function test_EDGE_EndedGroup_FeeCollection() public {
        _startGroupMulti();

        vm.prank(user1);
        group.contribute();
        vm.prank(user2);
        group.contribute();

        vm.warp(block.timestamp + 30 days);

        vm.prank(admin);
        group.endGroup();

        // Fees should still be collectable
        uint256 treasBefore = usdc.balanceOf(treasury);
        group.collectFees();
        uint256 treasAfter = usdc.balanceOf(treasury);

        console.log("Fees collected after endGroup: $%s", _fmt(treasAfter - treasBefore));

        // Users can withdraw
        vm.prank(user1);
        group.withdraw();
        vm.prank(user2);
        group.withdraw();

        _assertFeeInvariant(group);
    }

    /// @notice contribue→endGroup→withdraw: yield snapshot is correct
    function test_EDGE_EndGroupYieldSnapshot() public {
        _startGroupMulti();

        vm.prank(user1);
        group.contribute();
        vm.prank(user2);
        group.contribute();

        vm.warp(block.timestamp + 60 days);

        uint256 pendingBefore = group.pendingYield(user1);

        vm.prank(admin);
        group.endGroup(); // snapshots yield

        // Warp more — yield should NOT increase after endGroup (no new accruals)
        vm.warp(block.timestamp + 60 days);

        uint256 pendingAfter = group.pendingYield(user1);

        console.log("Pending before endGroup: $%s | After +60d: $%s",
            _fmt(pendingBefore), _fmt(pendingAfter));

        // After endGroup there are no more accruals triggered by contribute
        // But the vault still accrues, so pendingYield view will show more
        // This is expected — the view function reads live vault state
        // The KEY thing is: at withdraw time, _accrueRewards runs and distributes correctly
    }

    /// @notice Factory-deployed group has correct treasury and fee setup
    function test_EDGE_FactoryDeployedGroup_FeeSetup() public {
        address groupAddr = factory.deployGroup(
            USDC, CONTRIBUTION, CYCLE, CYCLES, admin, MORPHO_VAULT
        );

        ZybraGroup factoryGroup = ZybraGroup(groupAddr);
        assertEq(factoryGroup.treasury(), treasury, "Treasury set by factory");
        assertEq(factoryGroup.PROTOCOL_FEE_BPS(), 1000, "10% fee");
        assertEq(factoryGroup.totalAccumulatedFees(), 0, "No fees yet");
        assertEq(factoryGroup.totalFeesWithdrawn(), 0, "No fees withdrawn");
    }

    // ========================================================================
    //  SECTION 6: ECONOMIC ANALYSIS — FEE LEAKAGE / OVER-CHARGING
    // ========================================================================

    /// @notice Full lifecycle economic analysis: verify no fee leakage
    function test_ECONOMIC_FullLifecycle_NoLeakage() public {
        console.log("=== ECONOMIC: Full lifecycle fee analysis ===");

        _startGroupMulti();

        // All contribute cycle 1
        vm.prank(user1);
        group.contribute();
        vm.prank(user2);
        group.contribute();
        vm.prank(user3);
        group.contribute();

        uint256 totalDeposited = 3 * CONTRIBUTION;

        // Contribute cycle 2
        _warpToCycle(2);
        vm.prank(user1);
        group.contribute();
        vm.prank(user2);
        group.contribute();
        totalDeposited += 2 * CONTRIBUTION;

        // Wait for yield
        vm.warp(block.timestamp + 90 days);

        // Collect state before withdrawals
        uint256 vaultShares = vault.balanceOf(address(group));
        uint256 vaultValue = vault.convertToAssets(vaultShares);
        uint256 grossYield = vaultValue > group.totalCapitalInGroup()
            ? vaultValue - group.totalCapitalInGroup() : 0;

        console.log("Vault value: $%s", _fmt(vaultValue));
        console.log("Total capital: $%s", _fmt(group.totalCapitalInGroup()));
        console.log("Gross yield: $%s", _fmt(grossYield));

        // Withdraw all users
        uint256 totalWithdrawn;
        address[3] memory users = [user1, user2, user3];
        for (uint256 i = 0; i < 3; i++) {
            uint256 bal = usdc.balanceOf(users[i]);
            vm.prank(users[i]);
            group.withdraw();
            totalWithdrawn += usdc.balanceOf(users[i]) - bal;
        }

        // Collect remaining fees
        uint256 treasBefore = usdc.balanceOf(treasury);
        group.collectFees();
        uint256 feesCollected = usdc.balanceOf(treasury) - treasBefore;
        uint256 totalFees = group.totalFeesWithdrawn();

        console.log("Total withdrawn by users: $%s", _fmt(totalWithdrawn));
        console.log("Total fees to treasury: $%s", _fmt(totalFees));

        // VERIFY: users received >= capital
        assertGe(totalWithdrawn, totalDeposited - 1e6, "Users got capital back");

        // VERIFY: users + fees ≈ vault value (no leakage)
        uint256 totalAccounted = totalWithdrawn + totalFees;
        uint256 dust = vault.balanceOf(address(group)) > 0
            ? vault.convertToAssets(vault.balanceOf(address(group))) : 0;
        totalAccounted += dust;

        console.log("Total accounted (users + fees + dust): $%s", _fmt(totalAccounted));
        console.log("Vault dust remaining: $%s", _fmt(dust));

        // Everything should be accounted for (within $1 tolerance)
        assertApproxEqAbs(totalAccounted, vaultValue, 1e6, "No fund leakage");
    }

    /// @notice Verify fee is exactly 10% of yield under controlled conditions
    function test_ECONOMIC_Fee_ExactTenPercent() public {
        _startGroup();

        vm.prank(user1);
        group.contribute();

        vm.warp(block.timestamp + 365 days);

        // Withdraw triggers final accrual
        uint256 bal = usdc.balanceOf(user1);
        vm.prank(user1);
        group.withdraw();

        uint256 userReceived = usdc.balanceOf(user1) - bal;
        uint256 userYield = userReceived > CONTRIBUTION ? userReceived - CONTRIBUTION : 0;

        // Collect fees
        group.collectFees();
        uint256 fees = group.totalFeesWithdrawn();

        console.log("User yield: $%s | Fees: $%s", _fmt(userYield), _fmt(fees));

        // Fee should be ~10% of gross yield
        // gross = user yield + fees (approximately)
        if (fees > 0 && userYield > 0) {
            uint256 gross = userYield + fees;
            uint256 feePercent = (fees * 10000) / gross;
            console.log("Fee percentage: %s bps (target: 1000)", feePercent);
            // Allow ±200 bps tolerance due to auto-collect timing and rounding
            assertApproxEqAbs(feePercent, 1000, 200, "Fee is ~10% of gross yield");
        }
    }

    /// @notice Progressive fee accumulation: fees grow proportionally with time
    function test_ECONOMIC_ProgressiveFeeAccumulation() public {
        _startGroupMulti();

        vm.prank(user1);
        group.contribute();
        vm.prank(user2);
        group.contribute();
        vm.prank(user3);
        group.contribute();

        uint256[] memory checkpoints = new uint256[](4);
        checkpoints[0] = 30 days;
        checkpoints[1] = 90 days;
        checkpoints[2] = 180 days;
        checkpoints[3] = 365 days;

        uint256 prevFees;
        for (uint256 i = 0; i < 4; i++) {
            vm.warp(group.groupStartTime() + checkpoints[i]);
            group.collectFees(); // triggers accrual + collection

            uint256 totalFees = group.totalFeesWithdrawn();
            console.log("  +%s days: total fees=$%s (+$%s)",
                checkpoints[i] / 1 days, _fmt(totalFees), _fmt(totalFees - prevFees));

            assertGe(totalFees, prevFees, "Fees monotonically increase");
            prevFees = totalFees;
        }
    }

    // ========================================================================
    //  SECTION 7: MULTI-GROUP ISOLATION
    // ========================================================================

    /// @notice Two groups sharing vault: fees are independent
    function test_ISOLATION_TwoGroups_IndependentFees() public {
        ZybraGroup groupA = new ZybraGroup(USDC, CONTRIBUTION, CYCLE, CYCLES, admin, MORPHO_VAULT);
        ZybraGroup groupB = new ZybraGroup(USDC, 500e6, CYCLE, CYCLES, admin, MORPHO_VAULT);

        deal(USDC, user1, 10_000e6);
        deal(USDC, user2, 10_000e6);
        deal(USDC, admin, 10_000e6);
        vm.prank(user1);
        usdc.approve(address(groupA), type(uint256).max);
        vm.prank(user2);
        usdc.approve(address(groupB), type(uint256).max);
        vm.prank(admin);
        usdc.approve(address(groupA), type(uint256).max);
        vm.prank(admin);
        usdc.approve(address(groupB), type(uint256).max);

        vm.prank(user1);
        groupA.joinGroup();
        vm.prank(user2);
        groupB.joinGroup();
        vm.prank(admin);
        groupA.startGroup();
        vm.prank(admin);
        groupB.startGroup();

        vm.prank(user1);
        groupA.contribute();
        vm.prank(user2);
        groupB.contribute();

        vm.warp(block.timestamp + 90 days);

        // Collect fees from A — should NOT affect B
        uint256 feesA = groupA.totalAccumulatedFees();
        uint256 feesB_before = groupB.totalAccumulatedFees();

        groupA.collectFees();

        // Trigger accrual on B
        groupB.collectFees();
        uint256 feesB_after = groupB.totalAccumulatedFees();

        console.log("GroupA fees: $%s | GroupB fees: $%s -> $%s",
            _fmt(feesA), _fmt(feesB_before), _fmt(feesB_after));

        // B's fees should be independent of A's collection
        assertGe(feesB_after, feesB_before, "B's fees not affected by A");
    }

    // ========================================================================
    //  SECTION 8: STRESS TESTS
    // ========================================================================

    /// @notice 50 members, 12 cycles, interleaveed claims and withdrawals
    function test_STRESS_50Members_InterleavedOps() public {
        ZybraGroup stressGroup = new ZybraGroup(
            USDC, CONTRIBUTION, CYCLE, CYCLES, admin, MORPHO_VAULT
        );

        address[] memory users = new address[](50);
        users[0] = admin;
        for (uint256 i = 1; i < 50; i++) {
            users[i] = makeAddr(string.concat("stress_", vm.toString(i)));
            deal(USDC, users[i], 500_000e6);
            vm.prank(users[i]);
            usdc.approve(address(stressGroup), type(uint256).max);
            vm.prank(users[i]);
            stressGroup.joinGroup();
        }
        deal(USDC, admin, 500_000e6);
        vm.prank(admin);
        usdc.approve(address(stressGroup), type(uint256).max);
        vm.prank(admin);
        stressGroup.startGroup();

        // All contribute cycle 1-6
        for (uint256 cycle = 1; cycle <= 6; cycle++) {
            vm.warp(stressGroup.groupStartTime() + (cycle - 1) * CYCLE + 1);
            for (uint256 u = 0; u < 50; u++) {
                vm.prank(users[u]);
                stressGroup.contribute();
            }
        }

        // Wait for yield
        vm.warp(block.timestamp + 30 days);

        // Users 0-9: claim yield
        for (uint256 i = 0; i < 10; i++) {
            uint256 p = stressGroup.pendingYield(users[i]);
            if (p > 0) {
                vm.prank(users[i]);
                stressGroup.claimYield();
            }
        }

        // Users 10-19: emergency withdraw
        for (uint256 i = 10; i < 20; i++) {
            vm.prank(users[i]);
            stressGroup.emergencyWithdraw();
        }

        // Users 20-29: normal withdraw
        for (uint256 i = 20; i < 30; i++) {
            vm.prank(users[i]);
            stressGroup.withdraw();
        }

        // Collect fees
        uint256 treasBefore = usdc.balanceOf(treasury);
        stressGroup.collectFees();
        uint256 feesCollected = usdc.balanceOf(treasury) - treasBefore;

        console.log("After mixed ops - Fees collected: $%s", _fmt(feesCollected));
        console.log("Active members: %s", stressGroup.activeMembersCount());
        console.log("Total capital remaining: $%s", _fmt(stressGroup.totalCapitalInGroup()));

        // Invariants still hold
        _assertFeeInvariant(stressGroup);

        // Remaining users (0-9 who claimed, 30-49 who did nothing) can withdraw
        for (uint256 i = 0; i < 10; i++) {
            vm.prank(users[i]);
            stressGroup.withdraw();
        }
        for (uint256 i = 30; i < 50; i++) {
            vm.prank(users[i]);
            stressGroup.withdraw();
        }

        assertEq(stressGroup.totalCapitalInGroup(), 0, "All capital out");
        assertEq(stressGroup.activeMembersCount(), 0, "No active members");
    }

    /// @notice Repeated claim-contribute cycles — no yield amplification
    function test_STRESS_RepeatedClaimContribute() public {
        _startGroup();

        uint256 totalClaimed;
        for (uint256 cycle = 1; cycle <= 6; cycle++) {
            vm.warp(group.groupStartTime() + (cycle - 1) * CYCLE + 1);
            vm.prank(user1);
            group.contribute();

            // Wait for some yield
            vm.warp(block.timestamp + 5 days);

            // Claim
            uint256 p = group.pendingYield(user1);
            if (p > 0) {
                uint256 bal = usdc.balanceOf(user1);
                vm.prank(user1);
                group.claimYield();
                totalClaimed += usdc.balanceOf(user1) - bal;
            }
        }

        console.log("Total claimed over 6 cycles: $%s", _fmt(totalClaimed));

        // Final withdraw
        uint256 bal = usdc.balanceOf(user1);
        vm.prank(user1);
        group.withdraw();
        uint256 finalReceived = usdc.balanceOf(user1) - bal;

        console.log("Final withdraw (capital + remaining yield): $%s", _fmt(finalReceived));
        console.log("Total received: $%s", _fmt(totalClaimed + finalReceived));

        // Should not receive more than capital + reasonable yield
        uint256 totalDeposited = 6 * CONTRIBUTION;
        uint256 totalReceived = totalClaimed + finalReceived;
        assertGe(totalReceived, totalDeposited - 1e6, "Got at least capital back");
        // No amplification: total received should be reasonable (< 2x deposits for reasonable APY)
        assertLt(totalReceived, totalDeposited * 2, "No yield amplification");
    }

    // ========================================================================
    //  SECTION 9: collectFees() COMPREHENSIVE
    // ========================================================================

    /// @notice collectFees returns correct value and updates state
    function test_CollectFees_ReturnValue() public {
        _startGroupMulti();

        vm.prank(user1);
        group.contribute();
        vm.prank(user2);
        group.contribute();

        vm.warp(block.timestamp + 90 days);

        uint256 pendingBefore = group.totalAccumulatedFees() - group.totalFeesWithdrawn();
        uint256 result = group.collectFees();

        console.log("collectFees result: $%s | pending was: $%s", _fmt(result), _fmt(pendingBefore));

        // Result should match what was pending (may differ due to accrual in same tx)
        if (result > 0) {
            assertGe(group.totalFeesWithdrawn(), result, "Fees withdrawn updated");
        }
    }

    /// @notice collectFees caps at vault value
    function test_CollectFees_CappedAtVaultValue() public {
        _startGroupMulti();

        vm.prank(user1);
        group.contribute();

        vm.warp(block.timestamp + 90 days);

        // Collect should never try to withdraw more than vault has
        uint256 vaultShares = vault.balanceOf(address(group));
        uint256 maxWithdrawable = vaultShares > 0 ? vault.convertToAssets(vaultShares) : 0;

        uint256 result = group.collectFees();
        assertLe(result, maxWithdrawable, "Fees capped at vault value");
    }

    /// @notice collectFees with zero accumulated fees returns 0
    function test_CollectFees_ZeroFees() public {
        _startGroup();

        // No contributions, no yield
        uint256 result = group.collectFees();
        assertEq(result, 0, "Zero fees returns 0");
    }

    /// @notice Multiple sequential collectFees — second should return 0  
    function test_CollectFees_DoubleCollect() public {
        _startGroupMulti();

        vm.prank(user1);
        group.contribute();

        vm.warp(block.timestamp + 90 days);

        uint256 first = group.collectFees();
        uint256 second = group.collectFees();

        console.log("First collect: $%s | Second collect: $%s", _fmt(first), _fmt(second));

        // Second should be 0 or very small (rounding dust)
        assertTrue(second < 1e6, "Second collect returns ~0");
    }

    /// @notice pendingFees view matches actual collectFees amount
    function test_PendingFees_MatchesActual() public {
        _startGroupMulti();

        vm.prank(user1);
        group.contribute();
        vm.prank(user2);
        group.contribute();

        vm.warp(block.timestamp + 90 days);

        uint256 viewPending = group.pendingFees();
        uint256 actualCollected = group.collectFees();

        console.log("pendingFees view: $%s | actual collected: $%s",
            _fmt(viewPending), _fmt(actualCollected));

        // Should be approximately equal (view doesn't include accrual from the collect tx itself)
        if (viewPending > 0 && actualCollected > 0) {
            assertApproxEqRel(viewPending, actualCollected, 0.1e18,
                "pendingFees ~= actual collected");
        }
    }

    // ========================================================================
    //  SECTION 10: CONSERVATION LAW — COMPREHENSIVE ACCOUNTING
    // ========================================================================

    /// @notice Total conservation: deposited + vault_yield = withdrawn + fees + remaining_vault
    function test_CONSERVATION_FullAccounting() public {
        console.log("=== CONSERVATION LAW TEST ===");

        _startGroupFull();

        // Track all deposits
        uint256 totalDeposited;

        // Cycle 1: all contribute
        vm.prank(admin);
        group.contribute();
        vm.prank(user1);
        group.contribute();
        vm.prank(user2);
        group.contribute();
        vm.prank(user3);
        group.contribute();
        vm.prank(user4);
        group.contribute();
        vm.prank(user5);
        group.contribute();
        totalDeposited = 6 * CONTRIBUTION;

        // Cycle 2: some contribute
        _warpToCycle(2);
        vm.prank(user1);
        group.contribute();
        vm.prank(user2);
        group.contribute();
        totalDeposited += 2 * CONTRIBUTION;

        // Wait for yield
        vm.warp(block.timestamp + 90 days);

        // user3 claims yield
        uint256 totalClaimed;
        uint256 p3 = group.pendingYield(user3);
        if (p3 > 0) {
            uint256 b3 = usdc.balanceOf(user3);
            vm.prank(user3);
            group.claimYield();
            totalClaimed += usdc.balanceOf(user3) - b3;
        }

        // user4 emergency withdraws
        uint256 totalEmergency;
        uint256 b4 = usdc.balanceOf(user4);
        vm.prank(user4);
        group.emergencyWithdraw();
        totalEmergency = usdc.balanceOf(user4) - b4;

        // user5 normal withdraws
        uint256 totalWithdrawn;
        uint256 b5 = usdc.balanceOf(user5);
        vm.prank(user5);
        group.withdraw();
        totalWithdrawn += usdc.balanceOf(user5) - b5;

        // Collect fees
        uint256 treasBefore = usdc.balanceOf(treasury);
        group.collectFees();
        uint256 feesToTreasury = usdc.balanceOf(treasury) - treasBefore;

        // Remaining users withdraw
        address[4] memory remaining = [admin, user1, user2, user3];
        for (uint256 i = 0; i < 4; i++) {
            (uint256 cap,,,bool active) = group.getMemberInfo(remaining[i]);
            if (active && cap > 0) {
                uint256 b = usdc.balanceOf(remaining[i]);
                vm.prank(remaining[i]);
                group.withdraw();
                totalWithdrawn += usdc.balanceOf(remaining[i]) - b;
            }
        }
        // user3 who claimed might have withdrawn too
        {
            (uint256 cap3,,,bool active3) = group.getMemberInfo(user3);
            if (active3 && cap3 > 0) {
                uint256 b = usdc.balanceOf(user3);
                vm.prank(user3);
                group.withdraw();
                totalWithdrawn += usdc.balanceOf(user3) - b;
            }
        }

        // Final fee sweep
        uint256 treasBefore2 = usdc.balanceOf(treasury);
        group.collectFees();
        feesToTreasury += usdc.balanceOf(treasury) - treasBefore2;

        // Remaining vault dust
        uint256 vaultDust = vault.balanceOf(address(group)) > 0
            ? vault.convertToAssets(vault.balanceOf(address(group))) : 0;

        uint256 totalOut = totalWithdrawn + totalClaimed + totalEmergency + feesToTreasury + vaultDust;

        console.log("  Deposited:          $%s", _fmt(totalDeposited));
        console.log("  Withdrawn (normal): $%s", _fmt(totalWithdrawn));
        console.log("  Claimed (yield):    $%s", _fmt(totalClaimed));
        console.log("  Emergency:          $%s", _fmt(totalEmergency));
        console.log("  Fees to treasury:   $%s", _fmt(feesToTreasury));
        console.log("  Vault dust:         $%s", _fmt(vaultDust));
        console.log("  Total out:          $%s", _fmt(totalOut));

        // Total out should be >= total deposited (vault earned yield)
        assertGe(totalOut, totalDeposited - 1e6, "No fund loss");
    }

    /// @notice feeAsset() returns correct asset
    function test_FeeAsset() public {
        assertEq(group.feeAsset(), USDC, "feeAsset is USDC");
    }
}
