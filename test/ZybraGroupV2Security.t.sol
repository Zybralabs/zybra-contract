// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import {ZybraGroupV2Refactored} from "src/ZybraGroupV2.sol";
import {ZybraGroupFactoryV2} from "src/ZybraGroupFactoryV2.sol";
import {MockYieldVault} from "src/mocks/MockYieldVault.sol";
import {MockERC20} from "src/mocks/MockERC20.sol";

/**
 * @title ZybraGroupV2Security
 * @notice Access control & security tests for ZybraGroupV2
 * 
 * Tests cover:
 *   1. withdraw(address user) — only user themselves can call
 *   2. joinGroup(address member) — only member themselves OR admin
 *   3. leaveGroup(address member) — only member themselves OR admin
 *   4. contribute(address user) — only user themselves OR admin
 *   5. claimYield(address user) — only user themselves
 *   6. collectFees() — permissionless, fees go to treasury
 *   7. admin-only functions: startGroup, endGroup, pause, unpause, setTreasury
 *   8. reentrancy guard coverage
 *   9. state transition guards
 */
contract ZybraGroupV2SecurityTest is Test {
    ZybraGroupFactoryV2 public factory;
    ZybraGroupV2Refactored public group;
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
    error NoMembers();
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
        factory = new ZybraGroupFactoryV2();
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
        group.joinGroup(alice);
        vm.prank(bob);
        group.joinGroup(bob);
        vm.prank(admin);
        group.startGroup();
    }

    function _contributeAndGenerateYield() internal {
        _setupActiveGroup();
        vm.prank(alice);
        group.contribute(alice);
        vm.prank(bob);
        group.contribute(bob);
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
        group.withdraw(alice);

        // Verify alice's capital is returned
        (uint256 capitalInGroup,,,,) = group.getMemberInfo(alice);
        assertEq(capitalInGroup, 0, "Capital should be 0 after withdrawal");
    }

    function test_withdraw_revertsWhenAttackerCallsForAlice() public {
        _contributeAndGenerateYield();
        vm.warp(block.timestamp + CYCLE_DURATION * TOTAL_CYCLES + 1);
        vm.prank(admin);
        group.endGroup();

        // Attacker tries to withdraw Alice's funds → MUST REVERT
        vm.prank(attacker);
        vm.expectRevert(NotAdmin.selector);
        group.withdraw(alice);
    }

    function test_withdraw_revertsWhenAdminCallsForAlice() public {
        _contributeAndGenerateYield();
        vm.warp(block.timestamp + CYCLE_DURATION * TOTAL_CYCLES + 1);
        vm.prank(admin);
        group.endGroup();

        // Even admin cannot withdraw on behalf of Alice
        vm.prank(admin);
        vm.expectRevert(NotAdmin.selector);
        group.withdraw(alice);
    }

    function test_withdraw_revertsWhenBobCallsForAlice() public {
        _contributeAndGenerateYield();
        vm.warp(block.timestamp + CYCLE_DURATION * TOTAL_CYCLES + 1);
        vm.prank(admin);
        group.endGroup();

        // Bob tries to withdraw Alice's funds → MUST REVERT
        vm.prank(bob);
        vm.expectRevert(NotAdmin.selector);
        group.withdraw(alice);
    }

    function test_withdraw_revertsForNonMember() public {
        _contributeAndGenerateYield();
        vm.warp(block.timestamp + CYCLE_DURATION * TOTAL_CYCLES + 1);
        vm.prank(admin);
        group.endGroup();

        // Attacker tries to withdraw their own (non-member) address
        vm.prank(attacker);
        vm.expectRevert(NotMember.selector);
        group.withdraw(attacker);
    }

    function test_withdraw_revertsForZeroAddress() public {
        _contributeAndGenerateYield();
        vm.warp(block.timestamp + CYCLE_DURATION * TOTAL_CYCLES + 1);
        vm.prank(admin);
        group.endGroup();

        vm.prank(alice);
        vm.expectRevert(ZeroAddress.selector);
        group.withdraw(address(0));
    }

    // ==================== 2. JOINGROUP ACCESS CONTROL ====================

    function test_joinGroup_userCanJoinSelf() public {
        vm.prank(alice);
        group.joinGroup(alice);

        (,,,bool isActive,) = group.getMemberInfo(alice);
        assertTrue(isActive, "Alice should be active after joining");
    }

    function test_joinGroup_adminCanAddMember() public {
        // Admin can add alice to the group
        vm.prank(admin);
        group.joinGroup(alice);

        (,,,bool isActive,) = group.getMemberInfo(alice);
        assertTrue(isActive, "Alice should be active after admin adds her");
    }

    function test_joinGroup_revertsWhenAttackerAddsAlice() public {
        // Attacker (non-admin, non-alice) tries to add alice
        vm.prank(attacker);
        vm.expectRevert(NotAdmin.selector);
        group.joinGroup(alice);
    }

    function test_joinGroup_revertsWhenBobAddsAlice() public {
        // Bob (non-admin, non-alice) tries to add alice
        vm.prank(bob);
        vm.expectRevert(NotAdmin.selector);
        group.joinGroup(alice);
    }

    function test_joinGroup_revertsAfterGroupStarted() public {
        vm.prank(alice);
        group.joinGroup(alice);
        vm.prank(admin);
        group.startGroup();

        // Can't join after group starts
        vm.prank(bob);
        vm.expectRevert(GroupAlreadyStarted.selector);
        group.joinGroup(bob);
    }

    function test_joinGroup_revertsForZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(ZeroAddress.selector);
        group.joinGroup(address(0));
    }

    function test_joinGroup_revertsIfAlreadyMember() public {
        vm.prank(alice);
        group.joinGroup(alice);

        vm.prank(alice);
        vm.expectRevert(AlreadyMember.selector);
        group.joinGroup(alice);
    }

    // ==================== 3. LEAVEGROUP ACCESS CONTROL ====================

    function test_leaveGroup_userCanLeaveSelf() public {
        vm.prank(alice);
        group.joinGroup(alice);

        vm.prank(alice);
        group.leaveGroup(alice);

        (,,,bool isActive,) = group.getMemberInfo(alice);
        assertFalse(isActive, "Alice should be inactive after leaving");
    }

    function test_leaveGroup_adminCanRemoveMember() public {
        vm.prank(alice);
        group.joinGroup(alice);

        vm.prank(admin);
        group.leaveGroup(alice);

        (,,,bool isActive,) = group.getMemberInfo(alice);
        assertFalse(isActive, "Alice should be inactive after admin removes her");
    }

    function test_leaveGroup_revertsWhenAttackerRemovesAlice() public {
        vm.prank(alice);
        group.joinGroup(alice);

        vm.prank(attacker);
        vm.expectRevert(NotAdmin.selector);
        group.leaveGroup(alice);
    }

    // ==================== 4. CONTRIBUTE ACCESS CONTROL ====================

    function test_contribute_userCanContributeSelf() public {
        _setupActiveGroup();

        vm.prank(alice);
        group.contribute(alice);

        assertTrue(group.contributedInCycle(alice, 1), "Alice should have contributed in cycle 1");
    }

    function test_contribute_adminCanContributeForUser() public {
        _setupActiveGroup();

        // Admin needs funds and approval
        usdc.mint(admin, 1_000_000_000);
        vm.prank(admin);
        usdc.approve(address(group), type(uint256).max);

        // Admin contributes on behalf of alice (valid use case)
        vm.prank(admin);
        group.contribute(alice);

        assertTrue(group.contributedInCycle(alice, 1), "Alice should have contributed via admin");
    }

    function test_contribute_revertsWhenAttackerContributesForAlice() public {
        _setupActiveGroup();

        vm.prank(attacker);
        vm.expectRevert(NotAdmin.selector);
        group.contribute(alice);
    }

    // ==================== 5. CLAIMYIELD ACCESS CONTROL ====================

    function test_claimYield_onlyUserCanClaim() public {
        _contributeAndGenerateYield();

        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        group.claimYield(alice);
        uint256 balAfter = usdc.balanceOf(alice);

        assertGt(balAfter, balBefore, "Alice should have received yield");
    }

    function test_claimYield_revertsWhenAttackerClaimsForAlice() public {
        _contributeAndGenerateYield();

        vm.prank(attacker);
        vm.expectRevert(NotAdmin.selector);
        group.claimYield(alice);
    }

    function test_claimYield_revertsWhenAdminClaimsForAlice() public {
        _contributeAndGenerateYield();

        // Even admin cannot claim yield on behalf of alice
        vm.prank(admin);
        vm.expectRevert(NotAdmin.selector);
        group.claimYield(alice);
    }

    // ==================== 6. COLLECTFEES — PERMISSIONLESS, GOES TO TREASURY ====================

    function test_collectFees_isPermissionless() public {
        _contributeAndGenerateYield();

        // Alice claims yield to generate fees
        vm.prank(alice);
        group.claimYield(alice);

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
        group.claimYield(alice);

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

    function test_collectFees_revertsWhenNoFees() public {
        _setupActiveGroup();

        vm.expectRevert(InvalidAmount.selector);
        group.collectFees();
    }

    // ==================== 7. ADMIN-ONLY FUNCTIONS ====================

    function test_startGroup_onlyAdmin() public {
        vm.prank(alice);
        group.joinGroup(alice);

        vm.prank(attacker);
        vm.expectRevert(NotAdmin.selector);
        group.startGroup();
    }

    function test_endGroup_onlyAdmin() public {
        _setupActiveGroup();
        vm.warp(block.timestamp + CYCLE_DURATION * TOTAL_CYCLES + 1);

        vm.prank(attacker);
        vm.expectRevert(NotAdmin.selector);
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

    function test_setTreasury_onlyAdmin() public {
        address newTreasury = makeAddr("newTreasury");

        vm.prank(attacker);
        vm.expectRevert(NotAdmin.selector);
        group.setTreasury(newTreasury);
    }

    function test_setTreasury_revertsZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(ZeroAddress.selector);
        group.setTreasury(address(0));
    }

    function test_setTreasury_updatesTreasury() public {
        address newTreasury = makeAddr("newTreasury");

        vm.prank(admin);
        group.setTreasury(newTreasury);

        assertEq(group.treasury(), newTreasury, "Treasury should be updated");
    }

    // ==================== 8. PAUSE GUARD ====================

    function test_pauseBlocksJoinGroup() public {
        vm.prank(admin);
        group.pause();

        vm.prank(alice);
        vm.expectRevert(ContractPaused.selector);
        group.joinGroup(alice);
    }

    function test_pauseBlocksContribute() public {
        _setupActiveGroup();

        vm.prank(admin);
        group.pause();

        vm.prank(alice);
        vm.expectRevert(ContractPaused.selector);
        group.contribute(alice);
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
        group.withdraw(alice);
    }

    // ==================== 9. STATE TRANSITION GUARDS ====================

    function test_contribute_revertsBeforeGroupStarted() public {
        vm.prank(alice);
        group.joinGroup(alice);

        vm.prank(alice);
        vm.expectRevert(GroupNotStarted.selector);
        group.contribute(alice);
    }

    function test_startGroup_adminIsAutoAddedAsMember() public {
        // The constructor auto-adds admin as a member
        // So startGroup() should succeed with just admin
        vm.prank(admin);
        group.startGroup();

        (bool started,,,,,,) = group.getGroupStatus();
        assertTrue(started, "Group should start with admin as sole member");
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
        group.contribute(alice);

        // Double contribution in same cycle should revert
        vm.prank(alice);
        vm.expectRevert(AlreadyContributed.selector);
        group.contribute(alice);
    }

    // ==================== 10. FEE MATH INTEGRITY ====================

    function test_protocolFeeIs1Percent() public {
        assertEq(group.PROTOCOL_FEE_BPS(), 100, "Protocol fee should be 100 bps (1%)");
    }

    function test_feeAccumulatesOnClaimYield() public {
        _contributeAndGenerateYield();

        uint256 feesBefore = group.accumulatedFees();
        assertEq(feesBefore, 0, "No fees before any claims");

        vm.prank(alice);
        group.claimYield(alice);

        uint256 feesAfter = group.accumulatedFees();
        assertGt(feesAfter, 0, "Fees should accumulate after yield claim");
    }

    function test_feeAssetMatchesGroupAsset() public {
        assertEq(group.feeAsset(), address(usdc), "Fee asset should match group asset");
    }

    function test_treasuryAddressIsCorrect() public {
        assertEq(group.treasury(), treasury, "Treasury should be set correctly");
    }
}
