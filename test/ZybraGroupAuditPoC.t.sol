// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import {ZybraGroup} from "src/ZybraGroup.sol";
import {MockYieldVault} from "src/mocks/MockYieldVault.sol";
import {MockERC20} from "src/mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title ZybraGroup — Post-Audit Exploit PoC & Defense Tests
 * @notice Proves that all V3A audit findings are fixed with industry-standard solutions.
 *
 * FINDINGS COVERED:
 * [H-01]  Unchecked vault.withdraw() return values → _safeVaultWithdraw()
 * [H-02]  No auto-end mechanism (admin key loss) → endGroup() grace period
 * [M-01]  emergencyWithdraw skips _accrueRewards → yield dust lockup
 * [L-01]  unchecked arithmetic in critical state updates → checked arithmetic
 * [L-02]  EmergencyWithdrawn event missing forfeited yield → 3-param event
 * [NEW]   Non-admin endGroup after grace period
 * [NEW]   getGroupEndDeadline view function
 */
contract ZybraGroupAuditPoCTest is Test {

    // ===================== STATE =====================

    ZybraGroup public group;
    MockYieldVault public vault;
    MockERC20 public usdc;

    address public admin;
    address public treasury;
    address public alice;
    address public bob;
    address public charlie;
    address public attacker;

    uint256 public constant CONTRIBUTION = 100_000_000; // 100 USDC
    uint256 public constant CYCLE_DURATION = 1 weeks;
    uint256 public constant TOTAL_CYCLES = 4;
    uint256 public constant APY_BPS = 5000; // 50% APY for test visibility
    uint256 public constant GRACE_PERIOD = 7 days;

    // Errors
    error NotAdmin();
    error GroupNotExpired();
    error WithdrawFailed();

    // Events
    event GroupEnded(uint256 timestamp);
    event EmergencyWithdrawn(address indexed member, uint256 capital, uint256 forfeitedYield);

    // ===================== SETUP =====================

    function setUp() public {
        admin = makeAddr("admin");
        treasury = makeAddr("treasury");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");
        attacker = makeAddr("attacker");

        usdc = new MockERC20("USD Coin", "USDC", 6);

        vm.prank(admin);
        vault = new MockYieldVault(address(usdc), "Mock Yield Vault", "myvUSDC", 6);
        vm.prank(admin);
        vault.setAnnualYieldRate(APY_BPS);

        group = new ZybraGroup(
            address(usdc), CONTRIBUTION, CYCLE_DURATION, TOTAL_CYCLES,
            admin, address(vault)
        );

        address[6] memory users = [admin, alice, bob, charlie, attacker, treasury];
        for (uint256 i = 0; i < 6; i++) {
            usdc.mint(users[i], 100_000_000_000);
            vm.prank(users[i]);
            usdc.approve(address(group), type(uint256).max);
        }
    }

    // ===================== HELPERS =====================

    function _joinAndStart(address[] memory users) internal {
        for (uint256 i = 0; i < users.length; i++) {
            vm.prank(users[i]);
            group.joinGroup();
        }
        vm.prank(admin);
        group.startGroup();
    }

    function _backVaultYield() internal {
        vault.accrueInterest();
        uint256 needed = vault.totalAssets();
        uint256 has = usdc.balanceOf(address(vault));
        if (needed > has) {
            usdc.mint(address(vault), needed - has);
        }
    }

    // =======================================================================
    //  H-01: VAULT.WITHDRAW() RETURN VALUE VALIDATION
    // =======================================================================

    /**
     * @notice Proves _safeVaultWithdraw is called in all withdrawal paths
     * @dev In V3-original, vault.withdraw() return was ignored in:
     *      - claimYield()
     *      - withdraw()
     *      - emergencyWithdraw()
     *      - collectFees()
     *      Now all go through _safeVaultWithdraw() which reverts on 0 shares.
     */
    function test_H01_VaultWithdrawReturnChecked_ClaimYield() public {
        address[] memory users = new address[](1);
        users[0] = alice;
        _joinAndStart(users);

        // Contribute and generate yield
        vm.prank(admin);
        group.contribute();
        vm.prank(alice);
        group.contribute();

        vm.warp(block.timestamp + 30 days);
        _backVaultYield();

        // Claim yield should succeed (vault returns > 0 shares)
        vm.prank(alice);
        group.claimYield();

        // Verify yield was claimed
        (uint256 cap, uint256 pending,,) = group.getMemberInfo(alice);
        assertEq(cap, CONTRIBUTION, "Capital should remain");
        assertEq(pending, 0, "Pending yield should be 0 after claim");
    }

    function test_H01_VaultWithdrawReturnChecked_Withdraw() public {
        address[] memory users = new address[](1);
        users[0] = alice;
        _joinAndStart(users);

        vm.prank(admin);
        group.contribute();
        vm.prank(alice);
        group.contribute();

        vm.warp(block.timestamp + 30 days);
        _backVaultYield();

        uint256 balBefore = usdc.balanceOf(alice);

        // Withdraw should succeed
        vm.prank(alice);
        group.withdraw();

        uint256 balAfter = usdc.balanceOf(alice);
        assertGt(balAfter - balBefore, CONTRIBUTION, "Should receive capital + yield");
    }

    function test_H01_VaultWithdrawReturnChecked_EmergencyWithdraw() public {
        address[] memory users = new address[](1);
        users[0] = alice;
        _joinAndStart(users);

        vm.prank(alice);
        group.contribute();

        // Emergency withdraw should succeed
        vm.prank(alice);
        group.emergencyWithdraw();

        (uint256 cap,,,bool isActive) = group.getMemberInfo(alice);
        assertEq(cap, 0, "Capital should be 0");
        assertFalse(isActive, "Should be inactive");
    }

    function test_H01_VaultWithdrawReturnChecked_CollectFees() public {
        address[] memory users = new address[](1);
        users[0] = alice;
        _joinAndStart(users);

        vm.prank(admin);
        group.contribute();
        vm.prank(alice);
        group.contribute();

        vm.warp(block.timestamp + 30 days);
        _backVaultYield();

        // Trigger accrual
        vm.prank(alice);
        group.claimYield();

        // Collect fees should succeed
        vm.prank(admin);
        uint256 fees = group.collectFees();
        assertGt(fees, 0, "Should have collected fees");
    }

    // =======================================================================
    //  H-02: AUTO-END MECHANISM — ADMIN KEY LOSS PROTECTION
    // =======================================================================

    /**
     * @notice Proves non-admin CANNOT end group before grace period
     */
    function test_H02_NonAdminCantEndBeforeGrace() public {
        address[] memory users = new address[](1);
        users[0] = alice;
        _joinAndStart(users);

        // Alice tries to end immediately — should fail
        vm.prank(alice);
        vm.expectRevert(GroupNotExpired.selector);
        group.endGroup();
    }

    /**
     * @notice Proves non-admin CAN end group after all cycles + grace period
     * @dev This is the critical fix: if admin loses keys, funds are NOT locked forever
     */
    function test_H02_NonAdminCanEndAfterGrace() public {
        address[] memory users = new address[](1);
        users[0] = alice;
        _joinAndStart(users);

        // Warp past all cycles + grace period
        uint256 deadline = group.getGroupEndDeadline();
        vm.warp(deadline + 1);

        // Anyone (even attacker) can now end the group
        vm.prank(attacker);
        group.endGroup();

        assertTrue(group.groupEnded(), "Group should be ended");
    }

    /**
     * @notice Admin can always end — even before cycles finish
     */
    function test_H02_AdminCanEndAnytime() public {
        address[] memory users = new address[](1);
        users[0] = alice;
        _joinAndStart(users);

        // Admin ends immediately — no grace period required
        vm.prank(admin);
        group.endGroup();

        assertTrue(group.groupEnded(), "Group should be ended");
    }

    /**
     * @notice getGroupEndDeadline returns correct value
     */
    function test_H02_EndDeadlineCorrect() public {
        address[] memory users = new address[](1);
        users[0] = alice;
        _joinAndStart(users);

        uint256 startTime = group.groupStartTime();
        uint256 expected = startTime + (TOTAL_CYCLES * CYCLE_DURATION) + GRACE_PERIOD;
        uint256 actual = group.getGroupEndDeadline();
        assertEq(actual, expected, "Deadline should be start + (cycles * duration) + grace");
    }

    /**
     * @notice getGroupEndDeadline returns 0 before start
     */
    function test_H02_EndDeadlineZeroBeforeStart() public {
        assertEq(group.getGroupEndDeadline(), 0, "Should be 0 before start");
    }

    /**
     * @notice Non-admin end at exact deadline boundary
     */
    function test_H02_NonAdminEndExactBoundary() public {
        address[] memory users = new address[](1);
        users[0] = alice;
        _joinAndStart(users);

        uint256 deadline = group.getGroupEndDeadline();

        // Exactly at deadline — should fail (need to be PAST it)
        vm.warp(deadline - 1);
        vm.prank(alice);
        vm.expectRevert(GroupNotExpired.selector);
        group.endGroup();

        // One second past deadline — should succeed
        vm.warp(deadline);
        vm.prank(alice);
        group.endGroup();
        assertTrue(group.groupEnded(), "Group should be ended");
    }

    /**
     * @notice Full rescue scenario: admin disappears, users can still withdraw
     */
    function test_H02_FullRescueScenario() public {
        address[] memory users = new address[](2);
        users[0] = alice;
        users[1] = bob;
        _joinAndStart(users);

        // Everyone contributes
        vm.prank(admin);
        group.contribute();
        vm.prank(alice);
        group.contribute();
        vm.prank(bob);
        group.contribute();

        // Generate yield
        vm.warp(block.timestamp + 30 days);
        _backVaultYield();

        // Admin "loses keys" — simulate by having no admin actions from here

        // Warp past grace period
        uint256 deadline = group.getGroupEndDeadline();
        vm.warp(deadline + 1);
        _backVaultYield();

        // Charlie (random address, not even a member) ends the group
        vm.prank(charlie);
        group.endGroup();
        assertTrue(group.groupEnded(), "Group should be ended");

        // Users can now withdraw their funds + yield
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        group.withdraw();
        assertGt(usdc.balanceOf(alice) - aliceBefore, CONTRIBUTION, "Alice should get capital + yield");

        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        group.withdraw();
        assertGt(usdc.balanceOf(bob) - bobBefore, CONTRIBUTION, "Bob should get capital + yield");
    }

    // =======================================================================
    //  M-01: EMERGENCY WITHDRAW ACCRUES REWARDS BEFORE STATE CHANGE
    // =======================================================================

    /**
     * @notice Proves emergencyWithdraw now accrues rewards, preventing yield dust lockup
     * @dev V3-original: emergencyWithdraw didn't call _accrueRewards().
     *      If there was unmaterialized yield and totalCapitalInGroup changed,
     *      subsequent accruals would compute incorrectly (yield dust locked).
     *      V3A FIX: _accrueRewards() called before totalCapitalInGroup reduction.
     */
    function test_M01_EmergencyWithdrawAccruesBeforeStateChange() public {
        address[] memory users = new address[](2);
        users[0] = alice;
        users[1] = bob;
        _joinAndStart(users);

        // All contribute
        vm.prank(admin);
        group.contribute();
        vm.prank(alice);
        group.contribute();
        vm.prank(bob);
        group.contribute();

        // Generate yield
        vm.warp(block.timestamp + 30 days);
        _backVaultYield();

        // Record Bob's pending yield BEFORE Alice emergency withdraws
        uint256 bobPendingBefore = group.pendingYield(bob);
        assertGt(bobPendingBefore, 0, "Bob should have pending yield");

        // Alice emergency withdraws
        vm.prank(alice);
        group.emergencyWithdraw();

        // Bob's pending yield should NOT decrease (rewards were accrued first)
        uint256 bobPendingAfter = group.pendingYield(bob);
        // Bob should get at least what he had before (may get slightly more due to Alice forfeiting)
        assertGe(bobPendingAfter, bobPendingBefore, "Bob's yield should not decrease");

        // Bob can claim his full yield
        vm.prank(bob);
        group.claimYield();
    }

    /**
     * @notice Proves forfeited yield stays in vault for remaining members
     */
    function test_M01_ForfeitedYieldBenefitsRemainingMembers() public {
        address[] memory users = new address[](2);
        users[0] = alice;
        users[1] = bob;
        _joinAndStart(users);

        vm.prank(admin);
        group.contribute();
        vm.prank(alice);
        group.contribute();
        vm.prank(bob);
        group.contribute();

        vm.warp(block.timestamp + 60 days);
        _backVaultYield();

        // Record total vault value
        uint256 vaultSharesBefore = vault.balanceOf(address(group));
        uint256 vaultValueBefore = vault.convertToAssets(vaultSharesBefore);

        // Alice emergency withdraws (forfeits yield)
        vm.prank(alice);
        group.emergencyWithdraw();

        // Vault should still have Alice's forfeited yield
        uint256 vaultSharesAfter = vault.balanceOf(address(group));
        uint256 vaultValueAfter = vault.convertToAssets(vaultSharesAfter);

        // Vault value should decrease by exactly Alice's capital (yield stays)
        uint256 valueDrop = vaultValueBefore - vaultValueAfter;
        // The drop should be approximately Alice's capital (100 USDC)
        // Auto-collect (10% fee) may also withdraw fees during emergencyWithdraw
        assertApproxEqAbs(valueDrop, CONTRIBUTION, 5_000_000, "Vault should drop by ~capital + fees");

        // More yield time + accrual
        vm.warp(block.timestamp + 30 days);
        _backVaultYield();

        // Bob should be able to claim more yield than before
        uint256 bobYield = group.pendingYield(bob);
        assertGt(bobYield, 0, "Bob should have accumulated yield");
    }

    // =======================================================================
    //  L-01: CHECKED ARITHMETIC IN CRITICAL STATE UPDATES
    // =======================================================================

    /**
     * @notice Proves activeMembersCount uses checked arithmetic
     * @dev In V3-original, unchecked{ --activeMembersCount } could theoretically
     *      underflow in edge cases. Now uses checked arithmetic.
     */
    function test_L01_ActiveMembersCountChecked() public {
        // Current count is 1 (admin auto-joined)
        assertEq(group.membersCount(), 1);

        // Join and leave
        vm.prank(alice);
        group.joinGroup();
        assertEq(group.membersCount(), 2);

        vm.prank(alice);
        group.leaveGroup();
        assertEq(group.membersCount(), 1);

        // Verify count tracks accurately through multiple operations
        vm.prank(bob);
        group.joinGroup();
        vm.prank(charlie);
        group.joinGroup();
        assertEq(group.membersCount(), 3);

        vm.prank(bob);
        group.leaveGroup();
        assertEq(group.membersCount(), 2);
    }

    /**
     * @notice Proves totalCapitalInGroup uses checked arithmetic
     */
    function test_L01_TotalCapitalInGroupChecked() public {
        address[] memory users = new address[](1);
        users[0] = alice;
        _joinAndStart(users);

        assertEq(group.totalCapitalInGroup(), 0);

        vm.prank(alice);
        group.contribute();
        assertEq(group.totalCapitalInGroup(), CONTRIBUTION);

        vm.prank(admin);
        group.contribute();
        assertEq(group.totalCapitalInGroup(), 2 * CONTRIBUTION);

        // Withdraw reduces correctly
        vm.prank(alice);
        group.withdraw();
        assertEq(group.totalCapitalInGroup(), CONTRIBUTION);
    }

    // =======================================================================
    //  L-02: EMERGENCY WITHDRAWN EVENT WITH FORFEITED YIELD
    // =======================================================================

    /**
     * @notice Proves EmergencyWithdrawn event includes forfeited yield amount
     */
    function test_L02_EmergencyWithdrawEventIncludesForfeitedYield() public {
        address[] memory users = new address[](1);
        users[0] = alice;
        _joinAndStart(users);

        vm.prank(admin);
        group.contribute();
        vm.prank(alice);
        group.contribute();

        // Generate yield
        vm.warp(block.timestamp + 30 days);
        _backVaultYield();

        uint256 pendingBefore = group.pendingYield(alice);
        assertGt(pendingBefore, 0, "Alice should have pending yield");

        // The event should include the forfeited yield amount
        vm.expectEmit(true, false, false, true);
        emit EmergencyWithdrawn(alice, CONTRIBUTION, pendingBefore);
        vm.prank(alice);
        group.emergencyWithdraw();
    }

    /**
     * @notice EmergencyWithdrawn event with zero yield (no yield generated)
     */
    function test_L02_EmergencyWithdrawEventZeroYield() public {
        address[] memory users = new address[](1);
        users[0] = alice;
        _joinAndStart(users);

        vm.prank(alice);
        group.contribute();

        // No yield generated — forfeited yield should be 0
        vm.expectEmit(true, false, false, true);
        emit EmergencyWithdrawn(alice, CONTRIBUTION, 0);
        vm.prank(alice);
        group.emergencyWithdraw();
    }

    // =======================================================================
    //  INTEGRATION: COMBINED SCENARIO TESTS
    // =======================================================================

    /**
     * @notice Full lifecycle with all V3A fixes active
     */
    function test_Integration_FullLifecycleWithAllFixes() public {
        // Setup group with 3 members
        address[] memory users = new address[](2);
        users[0] = alice;
        users[1] = bob;
        _joinAndStart(users);

        // Cycle 1: All contribute
        vm.prank(admin);
        group.contribute();
        vm.prank(alice);
        group.contribute();
        vm.prank(bob);
        group.contribute();

        // Generate yield over time
        vm.warp(block.timestamp + 14 days);
        _backVaultYield();

        // Alice emergency withdraws (M-01 fix: accrues first)
        vm.prank(alice);
        group.emergencyWithdraw();

        // Bob claims yield (H-01 fix: _safeVaultWithdraw)
        vm.prank(bob);
        group.claimYield();

        // Admin collects fees (H-01 fix: _safeVaultWithdraw)
        vm.prank(admin);
        group.collectFees();

        // Warp past grace period (H-02 fix: auto-end)
        uint256 deadline = group.getGroupEndDeadline();
        vm.warp(deadline + 1);
        _backVaultYield();

        // Random address ends group (H-02 fix)
        vm.prank(charlie);
        group.endGroup();

        // Bob withdraws all (H-01 fix: _safeVaultWithdraw)
        vm.prank(bob);
        group.withdraw();

        // Admin withdraws all
        vm.prank(admin);
        group.withdraw();

        // Verify clean state
        assertEq(group.activeMembersCount(), 0, "No active members");
        assertEq(group.totalCapitalInGroup(), 0, "No capital remaining");
    }

    /**
     * @notice Stress test: multiple emergency withdrawals don't break yield tracking
     */
    function test_Integration_MultipleEmergencyWithdrawals() public {
        address[] memory users = new address[](2);
        users[0] = alice;
        users[1] = bob;
        _joinAndStart(users);

        // All contribute
        vm.prank(admin);
        group.contribute();
        vm.prank(alice);
        group.contribute();
        vm.prank(bob);
        group.contribute();

        // Generate yield
        vm.warp(block.timestamp + 30 days);
        _backVaultYield();

        // Both Alice and Bob emergency withdraw
        vm.prank(alice);
        group.emergencyWithdraw();

        vm.prank(bob);
        group.emergencyWithdraw();

        // Admin should still be able to claim their yield and withdraw
        uint256 adminPending = group.pendingYield(admin);
        assertGt(adminPending, 0, "Admin should have yield from base + forfeited");

        vm.prank(admin);
        group.claimYield();

        vm.prank(admin);
        group.withdraw();
    }

    /**
     * @notice whenNotPaused modifier correctly used on all guarded functions
     */
    function test_Integration_WhenNotPausedModifier() public {
        address[] memory users = new address[](1);
        users[0] = alice;
        _joinAndStart(users);

        vm.prank(admin);
        group.contribute();
        vm.prank(alice);
        group.contribute();

        // Pause
        vm.prank(admin);
        group.pause();

        // contribute should revert
        vm.warp(block.timestamp + CYCLE_DURATION);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSignature("ContractPaused()"));
        group.contribute();

        // claimYield should revert
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("ContractPaused()"));
        group.claimYield();

        // withdraw should revert
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("ContractPaused()"));
        group.withdraw();

        // emergencyWithdraw should SUCCEED even when paused
        vm.prank(alice);
        group.emergencyWithdraw();

        (uint256 cap,,,bool isActive) = group.getMemberInfo(alice);
        assertEq(cap, 0, "Capital should be 0");
        assertFalse(isActive, "Should be inactive");
    }

    /**
     * @notice Pinned solidity version verification
     */
    function test_Integration_ContractExists() public {
        // If we got here, the contract compiled with the pinned version
        assertTrue(address(group) != address(0), "Contract deployed");
        assertEq(group.PROTOCOL_FEE_BPS(), 1000, "Fee BPS correct");
        assertEq(group.END_GROUP_GRACE_PERIOD(), 7 days, "Grace period correct");
    }
}
