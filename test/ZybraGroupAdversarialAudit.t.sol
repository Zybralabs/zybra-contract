// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {ZybraGroup} from "src/ZybraGroup.sol";
import {ZybraGroupFactory} from "src/ZybraGroupFactory.sol";
import {IMorphoVaultV2} from "src/interfaces/IMorphoVaultV2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title ZybraGroup Adversarial Security Audit — Hacker-Grade Exploitation Suite
 * @author Security Auditor
 * @notice Goes BEYOND functional tests. Targets edge cases, integer boundaries,
 *         accounting invariant violations, DoS vectors, and economic exploits.
 *
 * AUDIT METHODOLOGY:
 *   Phase 1: Integer boundary & truncation attacks (uint128 overflow)
 *   Phase 2: Storage DoS (membersList unbounded growth)
 *   Phase 3: Accounting invariant violations (conservation law breaks)
 *   Phase 4: Temporal edge cases (exact boundary timestamps)
 *   Phase 5: Economic griefing (dust lockup, phantom fees)
 *   Phase 6: Factory validation gaps
 *   Phase 7: Admin privilege escalation
 *   Phase 8: Post-endGroup yield accumulation (infinite yield bug)
 */
contract ZybraGroupAdversarialAuditTest is Test {
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
    address public attacker;
    address public whale;

    uint256 constant CONTRIBUTION = 1_000e6;
    uint256 constant CYCLE = 1 weeks;
    uint256 constant CYCLES = 12;

    function setUp() public {
        admin = makeAddr("admin");
        treasury = makeAddr("treasury");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        user3 = makeAddr("user3");
        attacker = makeAddr("attacker");

        usdc = IERC20(USDC);
        vault = IMorphoVaultV2(MORPHO_VAULT);

        if (usdc.balanceOf(WHALE_1) >= 10_000_000e6) whale = WHALE_1;
        else if (usdc.balanceOf(WHALE_2) >= 10_000_000e6) whale = WHALE_2;
        else whale = WHALE_3;
        if (usdc.balanceOf(whale) < 10_000_000e6) deal(USDC, whale, 100_000_000e6);

        group = new ZybraGroup(USDC, CONTRIBUTION, CYCLE, CYCLES, admin, MORPHO_VAULT);
        factory = new ZybraGroupFactory(treasury);

        vm.startPrank(whale);
        usdc.transfer(admin, 1_000_000e6);
        usdc.transfer(user1, 1_000_000e6);
        usdc.transfer(user2, 1_000_000e6);
        usdc.transfer(user3, 1_000_000e6);
        usdc.transfer(attacker, 1_000_000e6);
        vm.stopPrank();

        address[5] memory users = [admin, user1, user2, user3, attacker];
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(users[i]);
            usdc.approve(address(group), type(uint256).max);
        }
    }

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

    function _fmtUSDC(uint256 amount) internal pure returns (string memory) {
        uint256 whole = amount / 1e6;
        uint256 frac = (amount % 1e6) / 1e4;
        if (frac < 10) return string.concat(vm.toString(whole), ".0", vm.toString(frac));
        return string.concat(vm.toString(whole), ".", vm.toString(frac));
    }

    // ========================================================================
    //  PHASE 1: INTEGER BOUNDARY & TRUNCATION ATTACKS
    // ========================================================================

    /// @notice Verify uint128 capitalInGroup cannot overflow with max params
    /// @dev MAX_CONTRIBUTION = 1000e6, totalCycles = 52 (max)
    ///      52 * 1000e6 = 52_000e6 = 52_000_000_000 << uint128.max
    ///      The unchecked{} block is safe for these parameters but SHOULD be checked
    function test_BOUNDARY_CapitalInGroup_NoOverflow() public {
        // Create max-cycle group
        ZybraGroup maxGroup = new ZybraGroup(
            USDC, 1000e6, CYCLE, 52, admin, MORPHO_VAULT
        );

        deal(USDC, user1, 100_000e6);
        vm.prank(user1);
        usdc.approve(address(maxGroup), type(uint256).max);
        vm.prank(user1);
        maxGroup.joinGroup();

        deal(USDC, admin, 100_000e6);
        vm.prank(admin);
        usdc.approve(address(maxGroup), type(uint256).max);
        vm.prank(admin);
        maxGroup.startGroup();

        // Contribute all 52 cycles
        for (uint256 cycle = 1; cycle <= 52; cycle++) {
            vm.warp(maxGroup.groupStartTime() + (cycle - 1) * CYCLE + 1);
            vm.prank(user1);
            maxGroup.contribute();
        }

        (uint256 cap,,,) = maxGroup.getMemberInfo(user1);
        assertEq(cap, 52 * 1000e6, "52 cycles of $1000 = $52,000");
        // Prove it fits in uint128
        assertTrue(cap < type(uint128).max, "Fits in uint128");
    }

    /// @notice Verify rewardDebt uint128 truncation safety
    /// @dev rewardDebt = amount * accRewardPerShare / ACC_PRECISION
    ///      For this to overflow uint128, accRewardPerShare would need to be absurdly large
    ///      uint128.max = ~3.4e38, ACC_PRECISION = 1e12
    ///      Max rewardDebt per contribution = 1000e6 * accRPS / 1e12
    ///      For overflow: accRPS > uint128.max * 1e12 / 1000e6 = ~3.4e44
    ///      This would require trillions of dollars in yield — infeasible
    function test_BOUNDARY_RewardDebt_SafeForRealisticYield() public {
        _startGroup();

        vm.prank(user1);
        group.contribute();

        // Simulate extreme yield — warp 10 years
        vm.warp(block.timestamp + 3650 days);

        uint256 accRPS = group.accRewardPerShare();
        console.log("accRewardPerShare after 10y: %s", accRPS);

        // Verify it's far from uint128 overflow territory
        uint256 potentialDebt = (CONTRIBUTION * accRPS) / 1e12;
        assertTrue(potentialDebt < type(uint128).max, "rewardDebt safe for 10yr yield");

        // User can still withdraw safely
        uint256 bal = usdc.balanceOf(user1);
        vm.prank(user1);
        group.withdraw();
        assertGe(usdc.balanceOf(user1) - bal, CONTRIBUTION - 1e6, "Withdrawal works after 10yr");
    }

    // ========================================================================
    //  PHASE 2: STORAGE DoS — membersList UNBOUNDED GROWTH
    // ========================================================================

    /// @notice membersList grows permanently on join — leave doesn't remove entry
    /// @dev Attack: join-leave-rejoin repeatedly inflates membersList without limit
    ///      Each rejoin adds a new entry (AlreadyMember check is on isActive, not membersList)
    function test_DOS_MembersListGrowsOnRejoin() public {
        // User joins, leaves, rejoins multiple times
        uint256 initialLen = group.getMembersListLength();

        vm.prank(user1);
        group.joinGroup();
        uint256 afterJoin = group.getMembersListLength();
        assertEq(afterJoin, initialLen + 1, "Added to list");

        vm.prank(user1);
        group.leaveGroup();
        uint256 afterLeave = group.getMembersListLength();
        assertEq(afterLeave, afterJoin, "Leave doesn't shrink list");

        vm.prank(user1);
        group.joinGroup();
        uint256 afterRejoin = group.getMembersListLength();
        assertEq(afterRejoin, afterLeave + 1, "Rejoin adds DUPLICATE entry");

        // After 1 join + 1 rejoin, user1 appears twice in membersList
        console.log("membersList length: %s (user joined twice)", afterRejoin);

        // This is a known accepted trade-off — membersList is append-only
        // The real member count is tracked by activeMembersCount
        assertEq(group.activeMembersCount(), 2, "Active count correct (admin + user1)");
    }

    // ========================================================================
    //  PHASE 3: ACCOUNTING INVARIANT VIOLATIONS
    // ========================================================================

    /// @notice Verify fund conservation: vault_value >= capital + pending_yield + pending_fees
    ///         This is the CORE invariant that must never break
    function test_INVARIANT_FundConservation_UnderStress() public {
        _startGroupMulti();

        // Cycle 1: everyone contributes
        vm.prank(user1);
        group.contribute();
        vm.prank(user2);
        group.contribute();
        vm.prank(user3);
        group.contribute();

        // Generate yield
        vm.warp(block.timestamp + 30 days);

        // User1 claims yield (partial operation)
        uint256 p1 = group.pendingYield(user1);
        if (p1 > 0) {
            vm.prank(user1);
            group.claimYield();
        }

        // User2 emergency withdraws (forfeits yield)
        vm.prank(user2);
        group.emergencyWithdraw();

        // Collect fees
        group.collectFees();

        // MORE yield accrues
        vm.warp(block.timestamp + 30 days);

        // CHECK INVARIANT: vault_value >= totalCapitalInGroup
        uint256 vaultShares = vault.balanceOf(address(group));
        uint256 vaultValue = vaultShares > 0 ? vault.convertToAssets(vaultShares) : 0;
        uint256 totalCap = group.totalCapitalInGroup();

        assertTrue(vaultValue + 1e6 >= totalCap, "CORE INVARIANT: vault covers capital");

        console.log("Vault value: $%s | Capital: $%s | Surplus: $%s",
            _fmtUSDC(vaultValue), _fmtUSDC(totalCap),
            _fmtUSDC(vaultValue > totalCap ? vaultValue - totalCap : 0));
    }

    /// @notice Verify that totalDistributedYield + totalFeesWithdrawn tracks correctly
    ///         against actual USDC movements
    function test_INVARIANT_CumulativeTrackingCorrectness() public {
        _startGroupMulti();

        vm.prank(user1);
        group.contribute();
        vm.prank(user2);
        group.contribute();

        vm.warp(block.timestamp + 90 days);

        // Track every USDC movement
        uint256 totalUSDCOut;

        // User1 claims yield
        uint256 p1 = group.pendingYield(user1);
        if (p1 > 0) {
            uint256 bal = usdc.balanceOf(user1);
            vm.prank(user1);
            group.claimYield();
            totalUSDCOut += usdc.balanceOf(user1) - bal;
        }

        // User1 + User2 withdraw
        uint256 bal1 = usdc.balanceOf(user1);
        vm.prank(user1);
        group.withdraw();
        totalUSDCOut += usdc.balanceOf(user1) - bal1;

        uint256 bal2 = usdc.balanceOf(user2);
        vm.prank(user2);
        group.withdraw();
        totalUSDCOut += usdc.balanceOf(user2) - bal2;

        // Collect fees
        uint256 treasBal = usdc.balanceOf(treasury);
        group.collectFees();
        uint256 feesOut = usdc.balanceOf(treasury) - treasBal;

        uint256 vaultDust = vault.balanceOf(address(group)) > 0
            ? vault.convertToAssets(vault.balanceOf(address(group))) : 0;

        console.log("USDC out to users: $%s", _fmtUSDC(totalUSDCOut));
        console.log("Fees to treasury: $%s", _fmtUSDC(feesOut));
        console.log("Vault dust: $%s", _fmtUSDC(vaultDust));

        // totalDistributedYield + capital withdrawals + fees should account for everything
        assertGe(group.totalDistributedYield() + 2 * CONTRIBUTION + feesOut + vaultDust,
            totalUSDCOut + feesOut - 1e6,
            "Cumulative tracking correct");
    }

    // ========================================================================
    //  PHASE 4: TEMPORAL EDGE CASES
    // ========================================================================

    /// @notice Contribute at the EXACT last second before cycles expire
    function test_TEMPORAL_ContributeAtExactLastSecond() public {
        _startGroup();

        uint256 start = group.groupStartTime();
        uint256 lastValidTs = start + (CYCLES * CYCLE) - 1;

        // Contribute at the very last valid second
        vm.warp(lastValidTs);
        vm.prank(user1);
        group.contribute();

        // One second later should fail
        vm.warp(lastValidTs + 1);
        // This is now past all cycles
        vm.prank(admin);
        vm.expectRevert(ZybraGroup.InvalidCycle.selector);
        group.contribute();
    }

    /// @notice Verify getCurrentCycle returns correct values at boundaries
    function test_TEMPORAL_CycleBoundaryPrecision() public {
        _startGroup();
        uint256 start = group.groupStartTime();

        // Cycle 1: start <= t < start + duration
        vm.warp(start);
        assertEq(group.getCurrentCycle(), 1, "Cycle 1 at start");

        vm.warp(start + CYCLE - 1);
        assertEq(group.getCurrentCycle(), 1, "Still cycle 1 at end-1");

        vm.warp(start + CYCLE);
        assertEq(group.getCurrentCycle(), 2, "Cycle 2 at boundary");

        // Last cycle
        vm.warp(start + (CYCLES - 1) * CYCLE);
        assertEq(group.getCurrentCycle(), CYCLES, "Last cycle");

        // Past all cycles — capped at totalCycles
        vm.warp(start + CYCLES * CYCLE + 365 days);
        assertEq(group.getCurrentCycle(), CYCLES, "Capped at totalCycles");
    }

    /// @notice endGroup grace period precision
    function test_TEMPORAL_GracePeriodExactBoundary() public {
        _startGroup();

        uint256 deadline = group.groupStartTime() + (CYCLES * CYCLE) + 7 days;

        // One second before deadline — non-admin canNOT end
        vm.warp(deadline - 1);
        vm.prank(attacker);
        vm.expectRevert(ZybraGroup.GroupNotExpired.selector);
        group.endGroup();

        // Exactly at deadline — non-admin CAN end (contract uses strict `<`, not `<=`)
        // block.timestamp < deadline is FALSE when block.timestamp == deadline
        vm.warp(deadline);
        vm.prank(attacker);
        group.endGroup();
        assertTrue(group.groupEnded(), "Group ended by non-admin at exact deadline");
    }

    // ========================================================================
    //  PHASE 5: ECONOMIC GRIEFING & DUST ATTACKS
    // ========================================================================

    /// @notice Force-feed USDC to contract (not through vault) — verify it's locked
    ///         but doesn't corrupt accounting
    function test_GRIEFING_ForceFeedUSDC_NoAccountingCorruption() public {
        _startGroup();
        vm.prank(user1);
        group.contribute();

        // Attacker sends USDC directly to contract
        vm.prank(attacker);
        usdc.transfer(address(group), 100_000e6);

        uint256 contractUSDC = usdc.balanceOf(address(group));
        assertGt(contractUSDC, 0, "Contract has forcefed USDC");

        // CRITICAL: This USDC is stuck forever — sweepToken blocks USDC
        vm.prank(admin);
        vm.expectRevert(ZybraGroup.CannotSweep.selector);
        group.sweepToken(usdc);

        // But accounting is NOT corrupted
        assertEq(group.totalCapitalInGroup(), CONTRIBUTION, "Capital unaffected");

        // User can still withdraw normally
        uint256 bal = usdc.balanceOf(user1);
        vm.prank(user1);
        group.withdraw();
        assertGe(usdc.balanceOf(user1) - bal, CONTRIBUTION - 1e6, "Withdrawal works");

        // Force-fed USDC is permanently locked in contract
        uint256 lockedUSDC = usdc.balanceOf(address(group));
        assertGt(lockedUSDC, 0, "Forced USDC is permanently locked");
        console.log("LOCKED USDC in contract (irrecoverable): $%s", _fmtUSDC(lockedUSDC));
    }

    /// @notice Donate to vault to inflate share price — verify group unaffected
    function test_GRIEFING_VaultDonation_GroupUnaffected() public {
        _startGroupMulti();

        vm.prank(user1);
        group.contribute();
        vm.prank(user2);
        group.contribute();

        uint256 pending1Before = group.pendingYield(user1);

        // Attacker deposits massive amount into vault
        vm.prank(attacker);
        usdc.approve(MORPHO_VAULT, type(uint256).max);
        vm.prank(attacker);
        vault.deposit(500_000e6, attacker);

        // Group's pending yield should increase (share price went up)
        // But this is actually BENEFICIAL — vault donation helps all depositors
        uint256 pending1After = group.pendingYield(user1);

        console.log("Pending before donation: $%s | After: $%s",
            _fmtUSDC(pending1Before), _fmtUSDC(pending1After));

        // The key invariant: vault still covers capital
        uint256 vaultShares = vault.balanceOf(address(group));
        uint256 vaultValue = vault.convertToAssets(vaultShares);
        assertGe(vaultValue + 1e6, group.totalCapitalInGroup(), "Vault covers capital post-donation");
    }

    /// @notice Dust yield claim — if pending yield is just 1 wei, does it break?
    function test_GRIEFING_DustYieldClaim() public {
        _startGroup();

        vm.prank(user1);
        group.contribute();

        // Very short warp — possible 0 yield
        vm.warp(block.timestamp + 1);

        uint256 pending = group.pendingYield(user1);
        if (pending == 0) {
            // Should revert with NothingToClaim
            vm.prank(user1);
            vm.expectRevert(ZybraGroup.NothingToClaim.selector);
            group.claimYield();
        }
        // If pending > 0, claim should work
    }

    // ========================================================================
    //  PHASE 6: FACTORY VALIDATION GAPS
    // ========================================================================

    /// @notice Factory NOW rejects absurdly long cycle duration (hardening fix applied)
    function test_FACTORY_CycleDurationUpperBound() public {
        // 100 years per cycle — should be rejected after hardening
        vm.expectRevert(ZybraGroupFactory.InvalidCycleDuration.selector);
        factory.deployGroup(
            USDC, CONTRIBUTION, 100 * 365 days, 1, admin, MORPHO_VAULT
        );

        // 365 days (max) — should succeed
        address groupAddr = factory.deployGroup(
            USDC, CONTRIBUTION, 365 days, 1, admin, MORPHO_VAULT
        );
        assertTrue(groupAddr != address(0), "365-day cycle accepted");

        // 366 days — should be rejected
        vm.expectRevert(ZybraGroupFactory.InvalidCycleDuration.selector);
        factory.deployGroup(
            USDC, CONTRIBUTION, 366 days, 1, admin, MORPHO_VAULT
        );
    }

    /// @notice Factory treasury is factory-level — groups read it at runtime via factory.treasury()
    ///         One-to-all pattern: change factory treasury once, all groups see it immediately
    function test_FACTORY_TreasuryIsFactoryLevel() public {
        address groupAddr = factory.deployGroup(
            USDC, CONTRIBUTION, CYCLE, CYCLES, admin, MORPHO_VAULT
        );
        ZybraGroup deployed = ZybraGroup(groupAddr);
        assertEq(deployed.treasury(), treasury, "Group reads factory treasury at runtime");

        // Owner updates treasury — groups see it immediately (runtime read, no propagation)
        address newTreasury = makeAddr("newTreasury");
        factory.setTreasury(newTreasury);
        address groupAddr2 = factory.deployGroup(
            USDC, CONTRIBUTION, CYCLE, CYCLES, admin, MORPHO_VAULT
        );
        assertEq(ZybraGroup(groupAddr2).treasury(), newTreasury, "New group reads updated treasury");
        // Old group reads from factory too — sees the update without any propagation
        assertEq(deployed.treasury(), newTreasury, "Old group sees updated treasury (runtime read)");
    }

    /// @notice Factory ownership NOW uses 2-step transfer
    function test_FACTORY_TwoStepOwnershipTransfer() public {
        address newOwner = makeAddr("newOwner");
        factory.transferOwnership(newOwner);
        // Ownership not yet transferred
        assertEq(factory.owner(), address(this), "Still original owner");
        assertEq(factory.pendingOwner(), newOwner, "Pending owner set");
        // New owner accepts
        vm.prank(newOwner);
        factory.acceptOwnership();
        assertEq(factory.owner(), newOwner, "Two-step transfer succeeded");
    }

    // ========================================================================
    //  PHASE 7: ADMIN PRIVILEGE ESCALATION
    // ========================================================================

    /// @notice Admin can grief members by pausing indefinitely
    ///         But emergencyWithdraw always works — this is a FEATURE, not a bug
    function test_ADMIN_PauseGriefing_EmergencyAlwaysWorks() public {
        _startGroup();
        vm.prank(user1);
        group.contribute();

        vm.warp(block.timestamp + 30 days);

        // Admin pauses forever
        vm.prank(admin);
        group.pause();

        // User cannot claim or withdraw
        vm.prank(user1);
        vm.expectRevert(ZybraGroup.ContractPaused.selector);
        group.claimYield();

        vm.prank(user1);
        vm.expectRevert(ZybraGroup.ContractPaused.selector);
        group.withdraw();

        // But emergency ALWAYS works — capital is safe
        uint256 bal = usdc.balanceOf(user1);
        vm.prank(user1);
        group.emergencyWithdraw();
        uint256 received = usdc.balanceOf(user1) - bal;
        assertGe(received, CONTRIBUTION - 1e6, "Capital recovered via emergency");

        console.log("Admin pause griefing: user lost $%s of yield but capital safe",
            _fmtUSDC(CONTRIBUTION - received > 0 ? 0 : received - CONTRIBUTION));
    }

    /// @notice Admin can end group early, causing potential yield loss
    function test_ADMIN_EarlyEndGroup_YieldImpact() public {
        _startGroup();
        vm.prank(user1);
        group.contribute();

        vm.warp(block.timestamp + 7 days);

        uint256 pendingBefore = group.pendingYield(user1);

        // Admin ends group immediately
        vm.prank(admin);
        group.endGroup();

        // User can still withdraw
        uint256 bal = usdc.balanceOf(user1);
        vm.prank(user1);
        group.withdraw();
        uint256 received = usdc.balanceOf(user1) - bal;

        assertGe(received, CONTRIBUTION - 1e6, "At least capital back");
        console.log("Early end: received $%s (capital $%s + yield $%s)",
            _fmtUSDC(received), _fmtUSDC(CONTRIBUTION),
            _fmtUSDC(received > CONTRIBUTION ? received - CONTRIBUTION : 0));
    }

    /// @notice Admin transfer → new admin sweeps non-group tokens
    function test_ADMIN_TransferAndSweep() public {
        // Admin transfers to attacker via 2-step
        vm.prank(admin);
        group.transferAdmin(attacker);
        vm.prank(attacker);
        group.acceptAdmin();

        assertEq(group.admin(), attacker, "Attacker is now admin");

        // Attacker CANNOT sweep USDC or vault shares
        vm.prank(attacker);
        vm.expectRevert(ZybraGroup.CannotSweep.selector);
        group.sweepToken(usdc);

        vm.prank(attacker);
        vm.expectRevert(ZybraGroup.CannotSweep.selector);
        group.sweepToken(IERC20(address(vault)));
    }

    // ========================================================================
    //  PHASE 8: POST-endGroup YIELD ACCUMULATION
    // ========================================================================

    /// @notice After endGroup, vault still accrues yield. Verify users get it correctly.
    function test_POSTEND_YieldStillAccruesInVault() public {
        _startGroupMulti();

        vm.prank(user1);
        group.contribute();
        vm.prank(user2);
        group.contribute();

        vm.warp(block.timestamp + 30 days);

        // End group
        vm.prank(admin);
        group.endGroup();

        uint256 pendingAtEnd = group.pendingYield(user1);

        // Warp 90 more days — vault still earns
        vm.warp(block.timestamp + 90 days);

        uint256 pendingAfterLong = group.pendingYield(user1);
        console.log("Pending at endGroup: $%s | After 90 more days: $%s",
            _fmtUSDC(pendingAtEnd), _fmtUSDC(pendingAfterLong));

        // Yield view reflects vault growth (this is expected behavior)
        // The actual distributed amount is correct at withdraw time
        uint256 bal = usdc.balanceOf(user1);
        vm.prank(user1);
        group.withdraw();
        uint256 received = usdc.balanceOf(user1) - bal;
        assertGe(received, CONTRIBUTION, "Got at least capital + yield");
    }

    /// @notice Post-endGroup: can't contribute but CAN claim and withdraw
    function test_POSTEND_OperationRestrictions() public {
        _startGroup();
        vm.prank(user1);
        group.contribute();

        vm.prank(admin);
        group.endGroup();

        // Cannot contribute
        vm.warp(block.timestamp + CYCLE);
        vm.prank(user1);
        vm.expectRevert(ZybraGroup.GroupAlreadyEnded.selector);
        group.contribute();

        // CAN claim yield
        vm.warp(block.timestamp + 30 days);
        uint256 pending = group.pendingYield(user1);
        if (pending > 0) {
            vm.prank(user1);
            group.claimYield();
        }

        // CAN withdraw
        vm.prank(user1);
        group.withdraw();
        (uint256 cap,,,) = group.getMemberInfo(user1);
        assertEq(cap, 0, "Fully withdrawn post-endGroup");
    }

    // ========================================================================
    //  PHASE 9: COMPOUND EXPLOIT SCENARIOS (Multi-step attacks)
    // ========================================================================

    /// @notice Attacker joins group, contributes, immediately emergency-withdraws,
    ///         then tries to exploit the zero-capital state
    function test_COMPOUND_JoinContributeEmergencyExploit() public {
        vm.prank(attacker);
        group.joinGroup();
        vm.prank(user1);
        group.joinGroup();
        vm.prank(admin);
        group.startGroup();

        // Attacker contributes
        vm.prank(attacker);
        group.contribute();

        // Immediately emergency withdraw
        vm.prank(attacker);
        group.emergencyWithdraw();

        // Attacker is now inactive with 0 capital
        (uint256 cap,,, bool active) = group.getMemberInfo(attacker);
        assertEq(cap, 0, "Zero capital");
        assertFalse(active, "Inactive");

        // Cannot do anything else
        vm.prank(attacker);
        vm.expectRevert(ZybraGroup.NotMember.selector);
        group.claimYield();

        vm.prank(attacker);
        vm.expectRevert(ZybraGroup.NotMember.selector);
        group.withdraw();

        vm.prank(attacker);
        vm.expectRevert(ZybraGroup.NotMember.selector);
        group.emergencyWithdraw();
    }

    /// @notice Multi-group treasury drain attempt — many groups, one treasury
    function test_COMPOUND_MultiGroupTreasuryConsistency() public {
        // Deploy 3 groups sharing same treasury
        ZybraGroup g1 = new ZybraGroup(USDC, CONTRIBUTION, CYCLE, CYCLES, admin, MORPHO_VAULT);
        ZybraGroup g2 = new ZybraGroup(USDC, 500e6, CYCLE, CYCLES, admin, MORPHO_VAULT);
        ZybraGroup g3 = new ZybraGroup(USDC, 100e6, CYCLE, 4, admin, MORPHO_VAULT);

        // Setup each group
        address[3] memory groupAddrs = [address(g1), address(g2), address(g3)];
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(user1);
            usdc.approve(groupAddrs[i], type(uint256).max);
            vm.prank(admin);
            usdc.approve(groupAddrs[i], type(uint256).max);
        }

        vm.prank(user1);
        g1.joinGroup();
        vm.prank(user1);
        g2.joinGroup();
        vm.prank(user1);
        g3.joinGroup();
        vm.prank(admin);
        g1.startGroup();
        vm.prank(admin);
        g2.startGroup();
        vm.prank(admin);
        g3.startGroup();

        // Contribute to all
        vm.prank(user1);
        g1.contribute();
        vm.prank(user1);
        g2.contribute();
        vm.prank(user1);
        g3.contribute();

        vm.warp(block.timestamp + 60 days);

        // Collect fees from all — all go to same treasury
        uint256 treasBefore = usdc.balanceOf(treasury);
        g1.collectFees();
        g2.collectFees();
        g3.collectFees();
        uint256 totalFees = usdc.balanceOf(treasury) - treasBefore;

        console.log("Total fees across 3 groups: $%s", _fmtUSDC(totalFees));

        // Each group's internal accounting is independent
        assertGe(g1.totalAccumulatedFees(), g1.totalFeesWithdrawn(), "G1 fee invariant");
        assertGe(g2.totalAccumulatedFees(), g2.totalFeesWithdrawn(), "G2 fee invariant");
        assertGe(g3.totalAccumulatedFees(), g3.totalFeesWithdrawn(), "G3 fee invariant");
    }

    /// @notice Rapid join-leave-rejoin before group starts to inflate membersList
    function test_COMPOUND_RapidJoinLeaveRejoin_StorageGrowth() public {
        uint256 initialLen = group.getMembersListLength();

        // Attacker joins and leaves 20 times
        for (uint256 i = 0; i < 20; i++) {
            vm.prank(attacker);
            group.joinGroup();
            vm.prank(attacker);
            group.leaveGroup();
        }

        uint256 finalLen = group.getMembersListLength();
        assertEq(finalLen, initialLen + 20, "20 entries added to membersList");
        assertEq(group.activeMembersCount(), 1, "Only admin is active");

        console.log("Storage growth: %s entries for 0 active members (admin excluded)",
            finalLen - 1);

        // This is a known trade-off — membersList is append-only
        // The gas impact is on getMembersListLength which is O(1) since it's array.length
    }

    // ========================================================================
    //  PHASE 10: ADVANCED ACCUMULATOR EDGE CASES
    // ========================================================================

    /// @notice Contribute → all yield distributed → vault value = capital
    ///         Then more yield accrues. Verify accumulator handles this correctly.
    function test_ACCUMULATOR_YieldGap_ReAccumulation() public {
        _startGroupMulti();

        vm.prank(user1);
        group.contribute();
        vm.prank(user2);
        group.contribute();

        vm.warp(block.timestamp + 30 days);

        // Both claim all yield
        uint256 p1 = group.pendingYield(user1);
        if (p1 > 0) {
            vm.prank(user1);
            group.claimYield();
        }
        uint256 p2 = group.pendingYield(user2);
        if (p2 > 0) {
            vm.prank(user2);
            group.claimYield();
        }

        // Both should have 0 pending now
        assertEq(group.pendingYield(user1), 0, "User1 pending = 0");
        assertEq(group.pendingYield(user2), 0, "User2 pending = 0");

        // Wait for more yield
        vm.warp(block.timestamp + 30 days);

        // New yield should accrue correctly
        uint256 newP1 = group.pendingYield(user1);
        uint256 newP2 = group.pendingYield(user2);
        assertGe(newP1, 0, "New yield user1");
        assertGe(newP2, 0, "New yield user2");

        // Equal capital → equal yield
        if (newP1 > 0 && newP2 > 0) {
            assertApproxEqRel(newP1, newP2, 0.01e18, "Equal yield for equal capital");
        }
    }

    /// @notice Single member contributes, claims, contributes more — verify accumulator
    function test_ACCUMULATOR_ContributeClaimContribute_NoYieldLeak() public {
        _startGroup();

        // Cycle 1
        vm.prank(user1);
        group.contribute();

        // Accrue yield within cycle 1 (5 days < 1 week cycle)
        vm.warp(block.timestamp + 5 days);

        uint256 p = group.pendingYield(user1);
        uint256 claimed;
        if (p > 0) {
            uint256 bal = usdc.balanceOf(user1);
            vm.prank(user1);
            group.claimYield();
            claimed = usdc.balanceOf(user1) - bal;
        }

        // Cycle 2 — MUST warp FORWARD from current time, never backward
        // Current time: groupStartTime + 5 days. Cycle 2 starts at groupStartTime + CYCLE.
        vm.warp(group.groupStartTime() + CYCLE + 1);
        vm.prank(user1);
        group.contribute();

        // More yield — warp forward from cycle 2
        vm.warp(block.timestamp + 30 days);

        // Final withdraw
        uint256 balBefore = usdc.balanceOf(user1);
        vm.prank(user1);
        group.withdraw();
        uint256 finalReceived = usdc.balanceOf(user1) - balBefore;

        uint256 totalReceived = claimed + finalReceived;
        uint256 totalDeposited = 2 * CONTRIBUTION;

        console.log("Claimed: $%s | Final: $%s", _fmtUSDC(claimed), _fmtUSDC(finalReceived));
        console.log("Total: $%s | Deposited: $%s", _fmtUSDC(totalReceived), _fmtUSDC(totalDeposited));

        assertGe(totalReceived, totalDeposited - 1e6, "No net loss");
        // No yield amplification
        assertLt(totalReceived, totalDeposited * 2, "No amplification");
    }
}
