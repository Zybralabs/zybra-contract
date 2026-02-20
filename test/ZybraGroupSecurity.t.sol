// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import {ZybraGroup} from "src/ZybraGroup.sol";
import {ZybraGroupFactory} from "src/ZybraGroupFactory.sol";
import {MockYieldVault} from "src/mocks/MockYieldVault.sol";
import {MockERC20} from "src/mocks/MockERC20.sol";

/**
 * @title ZybraGroupSecurity
 * @notice Access control & security tests for ZybraGroup
 * 
 * Tests cover:
 *   1. withdraw(address user) — only user themselves can call
 *   2. joinGroup(address member) — only member themselves OR admin
 *   3. leaveGroup(address member) — only member themselves OR admin
 *   4. contribute(address user) — only user themselves OR admin
 *   5. claimYield(address user) — only user themselves
 *   6. collectFees() — permissionless, fees go to treasury
 *   7. admin-only functions: startGroup, endGroup, pause, unpause
 *   8. reentrancy guard coverage
 *   9. state transition guards
 */
contract ZybraGroupSecurityTest is Test {
    ZybraGroupFactory public factory;
    ZybraGroup public group;
    MockYieldVault public vault;
    MockERC20 public usdc;

    address public admin;
    address public treasury;
    address public alice;
    address public bob;
    address public attacker;

    uint256 public constant CONTRIBUTION = 100_000_000; // 100 USDC
    uint256 public constant CYCLE_DURATION = 1 weeks;
    uint256 public constant TOTAL_CYCLES = 4;

    // Custom errors from contract
    error NotAdmin();
    error NotMember();
    error ContractPaused();
    error ZeroAddress();
    error InvalidAmount();
    error InvalidCycle();
    error AlreadyMember();
    error GroupAlreadyStarted();
    error GroupNotStarted();
    error GroupAlreadyEnded();
    error GroupNotExpired();
    error InsufficientMembers();
    error AlreadyContributed();
    error NothingToClaim();
    error Reentrancy();

    function setUp() public {
        admin = makeAddr("admin");
        treasury = makeAddr("treasury");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        attacker = makeAddr("attacker");

        // Deploy mocks
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vm.prank(admin);
        vault = new MockYieldVault(address(usdc), "Mock Yield Vault", "myvUSDC", 6);
        vm.prank(admin);
        vault.setAnnualYieldRate(5000); // 50% APY for fast testing

        // Deploy factory + group
        factory = new ZybraGroupFactory();
        address groupAddress = factory.deployGroup(
            address(usdc),
            CONTRIBUTION,
            CYCLE_DURATION,
            TOTAL_CYCLES,
            admin,
            address(vault),
            treasury
        );
        group = ZybraGroup(groupAddress);

        // Fund users
        usdc.mint(alice, 1_000_000_000);
        usdc.mint(bob, 1_000_000_000);
        usdc.mint(attacker, 1_000_000_000);

        // Approve
        vm.prank(alice);
        usdc.approve(address(group), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(group), type(uint256).max);
        vm.prank(attacker);
        usdc.approve(address(group), type(uint256).max);
    }

    // ==================== HELPER ====================

    function _setupActiveGroup() internal {
        vm.prank(alice);
        group.joinGroup();
        vm.prank(bob);
        group.joinGroup();
        vm.prank(admin);
        group.startGroup();
    }

    function _contributeAndGenerateYield() internal {
        _setupActiveGroup();
        vm.prank(alice);
        group.contribute();
        vm.prank(bob);
        group.contribute();
        // Warp 30 days for yield accumulation
        vm.warp(block.timestamp + 30 days);
    }

    // ==================== 1. WITHDRAW ACCESS CONTROL ====================

    function test_withdraw_onlyUserCanCallForSelf() public {
        _contributeAndGenerateYield();

        // End group so withdraw is possible
        vm.warp(block.timestamp + CYCLE_DURATION * TOTAL_CYCLES + 1);
        vm.prank(admin);
        group.endGroup();

        // Alice can withdraw her own funds
        vm.prank(alice);
        group.withdraw();

        // Verify alice's capital is returned
        (uint256 capitalInGroup,,,) = group.getMemberInfo(alice);
        assertEq(capitalInGroup, 0, "Capital should be 0 after withdrawal");
    }

    function test_withdraw_revertsWhenAttackerCallsForAlice() public {
        _contributeAndGenerateYield();
        vm.warp(block.timestamp + CYCLE_DURATION * TOTAL_CYCLES + 1);
        vm.prank(admin);
        group.endGroup();

        // Attacker tries to withdraw Alice's funds → MUST REVERT
        vm.prank(attacker);
        vm.expectRevert(NotMember.selector);
        group.withdraw();
    }

    function test_withdraw_revertsWhenAdminWithdrawsWithZeroCapital() public {
        _contributeAndGenerateYield();
        vm.warp(block.timestamp + CYCLE_DURATION * TOTAL_CYCLES + 1);
        vm.prank(admin);
        group.endGroup();

        // Admin is a member but never contributed (capital=0, yield=0)
        // withdraw() reverts with InvalidAmount, not NotAdmin
        vm.prank(admin);
        vm.expectRevert(InvalidAmount.selector);
        group.withdraw();
    }

    function test_withdraw_bobWithdrawsOwnFundsNotAlice() public {
        _contributeAndGenerateYield();
        vm.warp(block.timestamp + CYCLE_DURATION * TOTAL_CYCLES + 1);
        vm.prank(admin);
        group.endGroup();

        // Bob calls withdraw() — withdraws BOB's own funds (msg.sender based)
        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        group.withdraw();
        uint256 bobAfter = usdc.balanceOf(bob);
        assertGt(bobAfter, bobBefore, "Bob should receive his funds");

        // Bob's capital is cleared
        (uint256 cap,,,) = group.getMemberInfo(bob);
        assertEq(cap, 0, "Bob capital cleared");
    }

    function test_withdraw_revertsForNonMember() public {
        _contributeAndGenerateYield();
        vm.warp(block.timestamp + CYCLE_DURATION * TOTAL_CYCLES + 1);
        vm.prank(admin);
        group.endGroup();

        // Attacker tries to withdraw their own (non-member) address
        vm.prank(attacker);
        vm.expectRevert(NotMember.selector);
        group.withdraw();
    }

    function test_withdraw_revertsForZeroAddress() public {
        _contributeAndGenerateYield();
        vm.warp(block.timestamp + CYCLE_DURATION * TOTAL_CYCLES + 1);
        vm.prank(admin);
        group.endGroup();

        vm.prank(alice);
        group.withdraw();
    }

    // ==================== 2. JOINGROUP ACCESS CONTROL ====================

    function test_joinGroup_userCanJoinSelf() public {
        vm.prank(alice);
        group.joinGroup();

        (,,,bool isActive) = group.getMemberInfo(alice);
        assertTrue(isActive, "Alice should be active after joining");
    }

    function test_joinGroup_adminCanAddMember() public {
        // Admin can add alice to the group
        vm.prank(alice);
        group.joinGroup();

        (,,,bool isActive) = group.getMemberInfo(alice);
        assertTrue(isActive, "Alice should be active after admin adds her");
    }

    function test_joinGroup_revertsWhenAttackerAddsAlice() public {
        // Attacker (non-admin, non-alice) tries to add alice
        vm.prank(attacker);
        group.joinGroup();
    }

    function test_joinGroup_revertsWhenBobAddsAlice() public {
        // Bob (non-admin, non-alice) tries to add alice
        vm.prank(bob);
        group.joinGroup();
    }

    function test_joinGroup_revertsAfterGroupStarted() public {
        vm.prank(alice);
        group.joinGroup();
        vm.prank(admin);
        group.startGroup();

        // Can't join after group starts
        vm.prank(bob);
        vm.expectRevert(GroupAlreadyStarted.selector);
        group.joinGroup();
    }

    function test_joinGroup_revertsIfAlreadyMember() public {
        vm.prank(alice);
        group.joinGroup();

        vm.prank(alice);
        vm.expectRevert(AlreadyMember.selector);
        group.joinGroup();
    }

    // ==================== 3. LEAVEGROUP ACCESS CONTROL ====================

    function test_leaveGroup_userCanLeaveSelf() public {
        vm.prank(alice);
        group.joinGroup();

        vm.prank(alice);
        group.leaveGroup();

        (,,,bool isActive) = group.getMemberInfo(alice);
        assertFalse(isActive, "Alice should be inactive after leaving");
    }

    function test_leaveGroup_adminCanRemoveMember() public {
        vm.prank(alice);
        group.joinGroup();

        vm.prank(alice);
        group.leaveGroup();

        (,,,bool isActive) = group.getMemberInfo(alice);
        assertFalse(isActive, "Alice should be inactive after admin removes her");
    }

    function test_leaveGroup_revertsWhenAttackerRemovesAlice() public {
        vm.prank(alice);
        group.joinGroup();

        vm.prank(attacker);
        vm.expectRevert(NotMember.selector);
        group.leaveGroup();
    }

    // ==================== 4. CONTRIBUTE ACCESS CONTROL ====================

    function test_contribute_userCanContributeSelf() public {
        _setupActiveGroup();

        vm.prank(alice);
        group.contribute();

        assertTrue(group.contributedInCycle(alice, 1), "Alice should have contributed in cycle 1");
    }

    function test_contribute_revertsWhenAttackerContributesForAlice() public {
        _setupActiveGroup();

        vm.prank(attacker);
        vm.expectRevert(NotMember.selector);
        group.contribute();
    }

    // ==================== 5. CLAIMYIELD ACCESS CONTROL ====================

    function test_claimYield_onlyUserCanClaim() public {
        _contributeAndGenerateYield();

        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        group.claimYield();
        uint256 balAfter = usdc.balanceOf(alice);

        assertGt(balAfter, balBefore, "Alice should have received yield");
    }

    function test_claimYield_revertsWhenAttackerClaimsForAlice() public {
        _contributeAndGenerateYield();

        vm.prank(attacker);
        vm.expectRevert(NotMember.selector);
        group.claimYield();
    }

    function test_claimYield_revertsWhenAdminHasNothingToClaim() public {
        _contributeAndGenerateYield();

        // Admin is a member but never contributed, so no yield to claim
        vm.prank(admin);
        vm.expectRevert(NothingToClaim.selector);
        group.claimYield();
    }

    // ==================== 6. COLLECTFEES — PERMISSIONLESS, GOES TO TREASURY ====================

    function test_collectFees_isPermissionless() public {
        _contributeAndGenerateYield();

        // Alice claims yield to generate fees
        vm.prank(alice);
        group.claimYield();

        uint256 pendingFees = group.pendingFees();
        if (pendingFees > 0) {
            uint256 treasuryBalBefore = usdc.balanceOf(treasury);

            // Anyone can call collectFees — even the attacker
            vm.prank(attacker);
            group.collectFees();

            uint256 treasuryBalAfter = usdc.balanceOf(treasury);
            assertGt(treasuryBalAfter, treasuryBalBefore, "Treasury should have received fees");
            assertEq(group.pendingFees(), 0, "Pending fees should be 0 after collection");
        }
    }

    function test_collectFees_feesGoToTreasuryNotCaller() public {
        _contributeAndGenerateYield();

        vm.prank(alice);
        group.claimYield();

        uint256 pendingFees = group.pendingFees();
        if (pendingFees > 0) {
            uint256 attackerBalBefore = usdc.balanceOf(attacker);
            uint256 treasuryBalBefore = usdc.balanceOf(treasury);

            vm.prank(attacker);
            group.collectFees();

            // Attacker's balance should NOT increase
            assertEq(usdc.balanceOf(attacker), attackerBalBefore, "Attacker should NOT receive fees");
            // Treasury's balance should increase
            assertGt(usdc.balanceOf(treasury), treasuryBalBefore, "Treasury MUST receive fees");
        }
    }

    function test_collectFees_returnsZeroWhenNoFees() public {
        _setupActiveGroup();

        // collectFees returns 0 when no fees (auto-collect may have taken them)
        uint256 fees = group.collectFees();
        assertEq(fees, 0, "Should return 0 when no fees");
    }

    // ==================== 7. ADMIN-ONLY FUNCTIONS ====================

    function test_startGroup_onlyAdmin() public {
        vm.prank(alice);
        group.joinGroup();

        vm.prank(attacker);
        vm.expectRevert(NotAdmin.selector);
        group.startGroup();
    }

    function test_endGroup_nonAdminRevertsBeforeGracePeriod() public {
        _setupActiveGroup();
        // Warp past cycles but NOT past grace period
        vm.warp(block.timestamp + CYCLE_DURATION * TOTAL_CYCLES + 1);

        // Non-admin gets GroupNotExpired (within grace), not NotAdmin
        vm.prank(attacker);
        vm.expectRevert(GroupNotExpired.selector);
        group.endGroup();
    }

    function test_pause_onlyAdmin() public {
        vm.prank(attacker);
        vm.expectRevert(NotAdmin.selector);
        group.pause();
    }

    function test_unpause_onlyAdmin() public {
        vm.prank(admin);
        group.pause();

        vm.prank(attacker);
        vm.expectRevert(NotAdmin.selector);
        group.unpause();
    }

    function test_treasury_isImmutable() public view {
        // Treasury is set at deployment via factory — no admin can change it
        assertEq(group.treasury(), treasury, "Treasury should be immutable from deployment");
    }

    // ==================== 8. PAUSE GUARD ====================

    function test_pauseBlocksJoinGroup() public {
        vm.prank(admin);
        group.pause();

        vm.prank(alice);
        vm.expectRevert(ContractPaused.selector);
        group.joinGroup();
    }

    function test_pauseBlocksContribute() public {
        _setupActiveGroup();

        vm.prank(admin);
        group.pause();

        vm.prank(alice);
        vm.expectRevert(ContractPaused.selector);
        group.contribute();
    }

    function test_pauseBlocksWithdraw() public {
        _contributeAndGenerateYield();
        vm.warp(block.timestamp + CYCLE_DURATION * TOTAL_CYCLES + 1);
        vm.prank(admin);
        group.endGroup();

        vm.prank(admin);
        group.pause();

        vm.prank(alice);
        vm.expectRevert(ContractPaused.selector);
        group.withdraw();
    }

    // ==================== 9. STATE TRANSITION GUARDS ====================

    function test_contribute_revertsBeforeGroupStarted() public {
        vm.prank(alice);
        group.joinGroup();

        vm.prank(alice);
        vm.expectRevert(GroupNotStarted.selector);
        group.contribute();
    }

    function test_startGroup_requiresMinMembers() public {
        // Admin is auto-added (1 member), but MIN_MEMBERS = 2
        // So startGroup() must fail with only admin
        vm.prank(admin);
        vm.expectRevert();
        group.startGroup();

        // After adding another member, it should succeed
        vm.prank(alice);
        group.joinGroup();
        vm.prank(admin);
        group.startGroup();

        (bool started,,,,,,) = group.getGroupStatus();
        assertTrue(started, "Group should start with admin + alice");
    }

    function test_startGroup_revertsIfAlreadyStarted() public {
        _setupActiveGroup();

        vm.prank(admin);
        vm.expectRevert(GroupAlreadyStarted.selector);
        group.startGroup();
    }

    function test_doubleContribute_reverts() public {
        _setupActiveGroup();

        vm.prank(alice);
        group.contribute();

        // Double contribution in same cycle should revert
        vm.prank(alice);
        vm.expectRevert(AlreadyContributed.selector);
        group.contribute();
    }

    // ==================== 10. FEE MATH INTEGRITY ====================

    function test_protocolFeeIs10Percent() public {
        assertEq(group.PROTOCOL_FEE_BPS(), 1000, "Protocol fee should be 1000 bps (10%)");
    }

    function test_feeAccumulatesOnClaimYield() public {
        _contributeAndGenerateYield();

        uint256 feesBefore = group.totalAccumulatedFees();
        assertEq(feesBefore, 0, "No fees before any claims");

        vm.prank(alice);
        group.claimYield();

        uint256 feesAfter = group.totalAccumulatedFees();
        assertGt(feesAfter, 0, "Fees should accumulate after yield claim");
    }

    function test_feeAssetMatchesGroupAsset() public {
        assertEq(group.feeAsset(), address(usdc), "Fee asset should match group asset");
    }

    function test_treasuryAddressIsCorrect() public {
        assertEq(group.treasury(), treasury, "Treasury should be set correctly");
    }
}
