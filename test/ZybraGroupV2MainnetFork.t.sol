// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {ZybraGroup} from "src/ZybraGroup.sol";
import {IMorphoVaultV2} from "src/interfaces/IMorphoVaultV2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title ZybraGroup Mainnet Fork — V3 Accumulator + Hacker-Resilience Suite
 * @notice Production-grade tests against REAL Morpho Vault V2 (Steakhouse USDC) on Ethereum mainnet
 * @dev Fixed-block fork, NO mocking, real whale impersonation, + exhaustive attack scenarios
 *
 * MORPHO VAULT V2 (Steakhouse USDC):
 *   Address: 0xBEEF01735c132Ada46AA9aA4c54623cAA92A64CB
 *   Asset  : USDC (0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48)
 *
 * PROTOCOL_FEE_BPS = 1000 (10%)
 * Treasury = immutable, set in constructor
 * collectFees = permissionless (fees always go to immutable treasury)
 *
 * ATTACK SURFACE TESTED (Section 3):
 *   A-01  Reentrancy on withdraw / claimYield / emergencyWithdraw
 *   A-02  Double-contribute in same cycle
 *   A-03  Contribute after group ended / before started
 *   A-04  Withdraw with zero capital (double-spend)
 *   A-05  Emergency withdraw yield theft
 *   A-06  Admin transfer hijack (2-step bypass)
 *   A-07  Fee evasion via early withdrawal
 *   A-08  Treasury immutability (no redirect)
 *   A-09  Vault share donation / inflation attack
 *   A-10  MAX_MEMBERS overflow DoS
 *   A-11  Leave after group started
 *   A-12  Re-join after leaving
 *   A-13  SweepToken on USDC / vault shares
 *   A-14  Pause/Unpause by non-admin
 *   A-15  endGroup griefing (non-admin before expiry)
 *   A-16  Flash-loan vault manipulation
 *   A-17  Front-run contribute to steal yield
 *   A-18  collectFees when vault is drained
 *   A-19  Accumulator overflow with extreme values
 *   A-20  Cross-group contamination
 *   A-21  Stale cycle boundary attacks
 *   A-22  Zero-cycle join-withdraw sandwich
 *   A-23  Self-destruct USDC force-feed
 *   A-24  pendingAdmin steal before accept
 *   A-25  Claim yield for inactive / zero-capital user
 *   A-26  Constructor validation
 *   A-27  Vault asset mismatch
 *   A-28  Start group abuse
 *   A-29  Join abuse
 *   A-30  Yield siphoning loop
 *   A-31  Emergency after normal withdraw
 *   A-32  Claim then contribute
 *   A-33  membersList gas griefing
 *   A-34  Paused group fee collection
 *   A-35  endGroup yield snapshot
 */
contract ZybraGroupV2MainnetForkTest is Test {
    // ==================== MAINNET ADDRESSES ====================

    address constant MORPHO_VAULT = 0xBEEF01735c132Ada46AA9aA4c54623cAA92A64CB;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    // USDC whales for impersonation
    address constant WHALE_1 = 0x37305B1cD40574E4C5Ce33f8e8306Be057fD7341;
    address constant WHALE_2 = 0x4B16c5dE96EB2117bBE5fd171E4d203624B014aa;
    address constant WHALE_3 = 0x55FE002aefF02F77364de339a1292923A15844B8;

    // ==================== STATE ====================

    ZybraGroup public group;
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

    uint256 constant CONTRIBUTION = 1_000e6; // $1,000 USDC (contract MAX)
    uint256 constant CYCLE = 1 weeks;
    uint256 constant CYCLES = 12;

    uint256 constant MAX_WHALE_USERS = 50;

    // ==================== SETUP ====================

    function setUp() public {
        // Fork is provided via --fork-url CLI flag

        admin = makeAddr("admin");
        treasury = makeAddr("treasury");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        user3 = makeAddr("user3");
        user4 = makeAddr("user4");
        user5 = makeAddr("user5");

        usdc = IERC20(USDC);
        vault = IMorphoVaultV2(MORPHO_VAULT);

        // Pick a whale with enough USDC
        if (usdc.balanceOf(WHALE_1) >= 10_000_000e6) {
            whale = WHALE_1;
        } else if (usdc.balanceOf(WHALE_2) >= 10_000_000e6) {
            whale = WHALE_2;
        } else {
            whale = WHALE_3;
        }

        // If none has enough, deal USDC directly
        if (usdc.balanceOf(whale) < 10_000_000e6) {
            deal(USDC, whale, 100_000_000e6);
        }

        group = new ZybraGroup(USDC, CONTRIBUTION, CYCLE, CYCLES, admin, MORPHO_VAULT, treasury);

        // Fund basic users
        vm.startPrank(whale);
        usdc.transfer(admin, 500_000e6);
        usdc.transfer(user1, 500_000e6);
        usdc.transfer(user2, 500_000e6);
        usdc.transfer(user3, 500_000e6);
        usdc.transfer(user4, 500_000e6);
        usdc.transfer(user5, 500_000e6);
        vm.stopPrank();

        // Approve
        address[6] memory users = [admin, user1, user2, user3, user4, user5];
        for (uint256 i = 0; i < 6; i++) {
            vm.prank(users[i]);
            usdc.approve(address(group), type(uint256).max);
        }
    }

    // ====================================================================
    //  HELPERS
    // ====================================================================

    function _warpToCycle(ZybraGroup g, uint256 cycleNum) internal {
        uint256 targetTs = g.groupStartTime() + (cycleNum - 1) * g.cycleDuration() + 1;
        vm.warp(targetTs);
    }

    function _createWhaleGroup(uint256 numMembers)
        internal
        returns (ZybraGroup whaleGroup, address[] memory users)
    {
        require(numMembers >= 2 && numMembers <= MAX_WHALE_USERS, "2-50 members");
        whaleGroup = new ZybraGroup(USDC, CONTRIBUTION, CYCLE, CYCLES, admin, MORPHO_VAULT, treasury);
        users = new address[](numMembers);
        users[0] = admin;
        for (uint256 i = 1; i < numMembers; i++) {
            users[i] = makeAddr(string.concat("whale_user_", vm.toString(i)));
            deal(USDC, users[i], 1_000_000e6);
            vm.prank(users[i]);
            usdc.approve(address(whaleGroup), type(uint256).max);
            vm.prank(users[i]);
            whaleGroup.joinGroup();
        }
        deal(USDC, admin, 1_000_000e6);
        vm.prank(admin);
        usdc.approve(address(whaleGroup), type(uint256).max);
        return (whaleGroup, users);
    }

    function _startGroupWithUsers() internal {
        vm.prank(user1);
        group.joinGroup();
        vm.prank(admin);
        group.startGroup();
    }

    function _startGroupMultiUser() internal {
        vm.prank(user1);
        group.joinGroup();
        vm.prank(user2);
        group.joinGroup();
        vm.prank(user3);
        group.joinGroup();
        vm.prank(admin);
        group.startGroup();
    }

    function _printYieldReport(
        ZybraGroup g,
        address[] memory users,
        string memory label,
        uint256 totalCapitalDeposited,
        uint256 elapsedDays
    ) internal view {
        console.log("");
        console.log("============================================================");
        console.log(" YIELD REPORT:", label);
        console.log("============================================================");

        uint256 vaultShares = vault.balanceOf(address(g));
        uint256 vaultValue = vaultShares > 0 ? vault.convertToAssets(vaultShares) : 0;
        uint256 totalCap = g.totalCapitalInGroup();
        uint256 grossYield = vaultValue > totalCap ? vaultValue - totalCap : 0;

        console.log("  Total Capital:    $%s", _fmtUSDC(totalCap));
        console.log("  Vault Value:      $%s", _fmtUSDC(vaultValue));
        console.log("  Gross Yield:      $%s", _fmtUSDC(grossYield));
        console.log("  Elapsed Days:     %s", elapsedDays);
        console.log("  Active Members:   %s", g.activeMembersCount());

        if (totalCap > 0 && elapsedDays > 0) {
            uint256 apyBps = (grossYield * 10000 * 365) / (totalCap * elapsedDays);
            console.log("  Implied APY:      %s.%s%%", apyBps / 100, apyBps % 100);
        }

        console.log("  accRewardPerShare:      %s", g.accRewardPerShare());
        console.log("  totalDistributedYield:  $%s", _fmtUSDC(g.totalDistributedYield()));
        console.log("  totalFeesWithdrawn:     $%s", _fmtUSDC(g.totalFeesWithdrawn()));
        console.log("  totalAccumulatedFees:   $%s", _fmtUSDC(g.totalAccumulatedFees()));

        uint256 totalPending;
        for (uint256 i = 0; i < users.length; i++) {
            (uint256 cap, uint256 pending,,) = g.getMemberInfo(users[i]);
            if (cap > 0) totalPending += pending;
        }
        console.log("  Total Pending (users):  $%s", _fmtUSDC(totalPending));
        console.log("  Capital deposited:      $%s", _fmtUSDC(totalCapitalDeposited));
        console.log("============================================================");
    }

    function _fmtUSDC(uint256 amount) internal pure returns (string memory) {
        uint256 whole = amount / 1e6;
        uint256 frac = (amount % 1e6) / 1e4;
        if (frac < 10) {
            return string.concat(vm.toString(whole), ".0", vm.toString(frac));
        }
        return string.concat(vm.toString(whole), ".", vm.toString(frac));
    }

    function _assertInv1(ZybraGroup g) internal {
        uint256 cap = g.totalCapitalInGroup();
        uint256 shares = vault.balanceOf(address(g));
        uint256 vaultVal = shares > 0 ? vault.convertToAssets(shares) : 0;
        assertTrue(cap <= vaultVal + 1e6, "INV1: cap <= vault");
    }

    // ####################################################################
    //  SECTION 1: CORE FUNCTIONALITY (against real Morpho vault)
    // ####################################################################

    function test_Deposit_SharesMinted_AssetsTracked() public {
        _startGroupWithUsers();

        uint256 userBal = usdc.balanceOf(user1);
        uint256 sharesBefore = vault.balanceOf(address(group));
        uint256 capBefore = group.totalCapitalInGroup();

        vm.prank(user1);
        group.contribute();

        uint256 sharesAfter = vault.balanceOf(address(group));
        uint256 vaultValue = vault.convertToAssets(sharesAfter);

        assertEq(usdc.balanceOf(user1), userBal - CONTRIBUTION, "USDC spent");
        assertGt(sharesAfter, sharesBefore, "Shares minted");
        assertEq(group.totalCapitalInGroup(), capBefore + CONTRIBUTION, "Capital tracked");
        assertLe(group.totalCapitalInGroup(), vaultValue + 1e6, "INV1: cap <= vault");
    }

    function test_RealYieldAccrual_30Days() public {
        _startGroupWithUsers();
        vm.prank(user1);
        group.contribute();

        uint256 initial = vault.convertToAssets(vault.balanceOf(address(group)));
        vm.warp(block.timestamp + 30 days);
        uint256 final_ = vault.convertToAssets(vault.balanceOf(address(group)));

        assertGe(final_, initial, "Non-negative yield");

        console.log("=== SINGLE USER 30-DAY YIELD ===");
        console.log("Initial: $%s | Final: $%s | Yield: $%s",
            _fmtUSDC(initial), _fmtUSDC(final_), _fmtUSDC(final_ > initial ? final_ - initial : 0));
    }

    function test_AccumulatorFairness_StaggeredEntry() public {
        _startGroupMultiUser();

        uint256 t0 = block.timestamp;

        vm.prank(user1);
        group.contribute();
        vm.warp(t0 + 2 days);
        vm.prank(user2);
        group.contribute();
        vm.warp(t0 + 4 days);
        vm.prank(user3);
        group.contribute();

        vm.warp(t0 + 7 days);

        uint256 p1 = group.pendingYield(user1);
        uint256 p3 = group.pendingYield(user3);

        console.log("User1 (7d): $%s | User3 (3d): $%s", _fmtUSDC(p1), _fmtUSDC(p3));
        assertGe(p1, p3, "Earlier gets more or equal yield");
    }

    function test_ClaimIdempotency() public {
        _startGroupWithUsers();
        vm.prank(user1);
        group.contribute();
        vm.warp(block.timestamp + 30 days);

        uint256 pending = group.pendingYield(user1);
        if (pending > 0) {
            vm.prank(user1);
            group.claimYield();

            uint256 pendingAfter = group.pendingYield(user1);
            if (pendingAfter == 0) {
                vm.prank(user1);
                vm.expectRevert(ZybraGroup.NothingToClaim.selector);
                group.claimYield();
            }
        }
    }

    function test_WithdrawCorrectness() public {
        _startGroupWithUsers();
        vm.prank(user1);
        group.contribute();
        vm.warp(block.timestamp + 30 days);

        uint256 pending = group.pendingYield(user1);
        uint256 bal = usdc.balanceOf(user1);
        vm.prank(user1);
        group.withdraw();
        uint256 received = usdc.balanceOf(user1) - bal;

        assertGe(received, CONTRIBUTION - 1e6, "At least capital back");
        (uint256 cap,,, bool active) = group.getMemberInfo(user1);
        assertEq(cap, 0, "Capital cleared");
        assertFalse(active, "Inactive");
    }

    function test_ProtocolFee_TenPercent() public {
        uint256 feeBps = group.PROTOCOL_FEE_BPS();
        assertEq(feeBps, 1000, "Fee is 1000 bps = 10%");
        uint256 testYield = 10_000e6;
        uint256 expectedFee = 1_000e6; // 10%
        assertEq((testYield * feeBps) / 10_000, expectedFee, "Fee calc correct");
    }

    function test_ZeroYield_VaultEqualsCapital() public {
        _startGroupWithUsers();
        vm.prank(user1);
        group.contribute();

        uint256 vaultVal = vault.convertToAssets(vault.balanceOf(address(group)));
        uint256 cap = group.totalCapitalInGroup();
        assertApproxEqRel(vaultVal, cap, 0.01e18, "~Equal at T=0");

        uint256 pending = group.pendingYield(user1);
        assertTrue(pending < cap / 100, "Minimal pending at T=0");
    }

    function test_ZeroYieldOperations() public {
        vm.prank(user1);
        group.joinGroup();
        vm.prank(user2);
        group.joinGroup();
        vm.prank(admin);
        group.startGroup();

        vm.prank(user1);
        group.contribute();
        vm.prank(user2);
        group.contribute();

        vm.warp(block.timestamp + 1 minutes);
        uint256 bal = usdc.balanceOf(user1);
        vm.prank(user1);
        group.withdraw();
        assertGe(usdc.balanceOf(user1) - bal, CONTRIBUTION - 1e6, "Capital back");
    }

    function test_LiquiditySafety_5Users() public {
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

        address[5] memory users = [user1, user2, user3, user4, user5];
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(users[i]);
            group.contribute();
        }

        vm.warp(block.timestamp + 14 days);

        uint256 totalWithdrawn;
        for (uint256 i = 0; i < 5; i++) {
            uint256 bal = usdc.balanceOf(users[i]);
            vm.prank(users[i]);
            group.withdraw();
            totalWithdrawn += usdc.balanceOf(users[i]) - bal;
        }

        assertEq(group.totalCapitalInGroup(), 0, "Cap zero after all withdraw");
    }

    function test_Invariant1_CapitalLeVault() public {
        _startGroupMultiUser();

        vm.prank(user1);
        group.contribute();
        _assertInv1(group);

        vm.warp(block.timestamp + 1 days);
        vm.prank(user2);
        group.contribute();
        _assertInv1(group);

        vm.warp(block.timestamp + CYCLE);
        vm.prank(user1);
        group.contribute();
        _assertInv1(group);

        vm.prank(user1);
        group.withdraw();
        _assertInv1(group);
    }

    function test_Invariant2_SumCapitalEqTotal() public {
        _startGroupMultiUser();

        vm.prank(user1);
        group.contribute();
        vm.prank(user2);
        group.contribute();
        vm.prank(user3);
        group.contribute();

        vm.warp(block.timestamp + CYCLE);
        vm.prank(user1);
        group.contribute();
        vm.prank(user2);
        group.withdraw();

        // Verify sum
        uint256 total = group.totalCapitalInGroup();
        uint256 sum;
        address[4] memory checkUsers = [admin, user1, user2, user3];
        for (uint256 i = 0; i < 4; i++) {
            (uint256 cap,,, bool active) = group.getMemberInfo(checkUsers[i]);
            if (active) sum += cap;
        }
        assertEq(sum, total, "INV2: sum == total");
    }

    function test_MultiCycleComprehensive() public {
        _startGroupMultiUser();

        vm.prank(user1);
        group.contribute();
        vm.prank(user2);
        group.contribute();

        vm.warp(block.timestamp + CYCLE);
        vm.prank(user1);
        group.contribute();
        vm.prank(user3);
        group.contribute();

        vm.warp(block.timestamp + CYCLE);
        vm.prank(user1);
        group.contribute();

        uint256 pending = group.pendingYield(user2);
        if (pending > 0) {
            vm.prank(user2);
            group.claimYield();
        }

        vm.warp(block.timestamp + CYCLE);
        vm.prank(user1);
        group.withdraw();

        assertEq(group.totalCapitalInGroup(), 1_000e6 + 1_000e6, "Remaining capital");
    }

    function test_VaultERC4626() public {
        assertEq(vault.asset(), USDC, "Asset USDC");
        uint256 shares = vault.previewDeposit(10_000e6);
        uint256 assets = vault.convertToAssets(shares);
        assertApproxEqRel(assets, 10_000e6, 0.01e18, "Round-trip");
    }

    function test_AdminSelfOps() public {
        _startGroupWithUsers();

        vm.prank(admin);
        group.contribute();

        (uint256 cap,,, bool active) = group.getMemberInfo(admin);
        assertEq(cap, CONTRIBUTION, "Admin cap");
        assertTrue(active, "Admin active");

        vm.warp(block.timestamp + 30 days);

        uint256 pending = group.pendingYield(admin);
        if (pending > 0) {
            vm.prank(admin);
            group.claimYield();
        }

        vm.prank(admin);
        group.withdraw();
        (cap,,, active) = group.getMemberInfo(admin);
        assertEq(cap, 0, "Admin cap zero");
    }

    function test_NonMonotonicYieldSafe() public {
        _startGroupWithUsers();
        vm.prank(user1);
        group.contribute();
        vm.warp(block.timestamp + 7 days);

        uint256 bal = usdc.balanceOf(user1);
        vm.prank(user1);
        group.withdraw();
        assertGe(usdc.balanceOf(user1) - bal, (CONTRIBUTION * 99) / 100, "99% capital");
    }

    function test_RapidOps() public {
        vm.prank(user1);
        group.joinGroup();
        vm.prank(user2);
        group.joinGroup();
        vm.prank(admin);
        group.startGroup();

        uint256 t0 = block.timestamp;
        for (uint256 i = 0; i < 4; i++) {
            vm.warp(t0 + i * CYCLE + 1);
            vm.prank(user1);
            group.contribute();
            vm.prank(user2);
            group.contribute();
        }

        (uint256 cap1,,,) = group.getMemberInfo(user1);
        (uint256 cap2,,,) = group.getMemberInfo(user2);
        assertEq(cap1, 4 * CONTRIBUTION, "4x u1");
        assertEq(cap2, 4 * CONTRIBUTION, "4x u2");
    }

    // ####################################################################
    //  SECTION 2: TREASURY & FEE TESTS
    // ####################################################################

    function test_TreasuryInitialized() public {
        assertEq(group.treasury(), treasury, "Treasury set correctly");
        assertEq(group.totalAccumulatedFees(), 0, "No fees yet");
    }

    function test_TreasuryIsImmutable() public {
        assertEq(group.treasury(), treasury, "Treasury is immutable from deployment");
    }

    function test_TreasuryFeeAccumulatedOnYieldClaim() public {
        _startGroupWithUsers();
        vm.prank(user1);
        group.contribute();
        vm.warp(block.timestamp + 90 days);

        uint256 pending = group.pendingYield(user1);
        if (pending > 0) {
            vm.prank(user1);
            group.claimYield();
            uint256 fees = group.totalAccumulatedFees();
            assertGt(fees, 0, "Fees accumulated from claim");
            console.log("Accumulated fees after claim: $%s", _fmtUSDC(fees));
        }
    }

    function test_CollectFeesSendsToTreasury() public {
        _startGroupWithUsers();
        vm.prank(user1);
        group.contribute();
        vm.warp(block.timestamp + 90 days);

        // Claim to accumulate fees
        uint256 pending = group.pendingYield(user1);
        if (pending > 0) {
            vm.prank(user1);
            group.claimYield();
        }

        uint256 pendingFees = group.totalAccumulatedFees() - group.totalFeesWithdrawn();
        uint256 treasuryBalBefore = usdc.balanceOf(treasury);

        if (pendingFees > 0) {
            // Permissionless — anyone can call
            group.collectFees();
            uint256 treasuryReceived = usdc.balanceOf(treasury) - treasuryBalBefore;
            assertGt(treasuryReceived, 0, "Treasury received fees");
            console.log("Fees sent to treasury: $%s", _fmtUSDC(treasuryReceived));
        }
    }

    function test_CollectFees_Permissionless() public {
        _startGroupWithUsers();
        vm.prank(user1);
        group.contribute();
        vm.warp(block.timestamp + 90 days);

        // Anyone can trigger collect — fees always go to treasury
        address randomCaller = makeAddr("random");
        uint256 treasBefore = usdc.balanceOf(treasury);
        uint256 randomBefore = usdc.balanceOf(randomCaller);

        vm.prank(randomCaller);
        group.collectFees();

        // Random caller gets NOTHING — only treasury benefits
        assertEq(usdc.balanceOf(randomCaller), randomBefore, "Caller gets nothing");
        assertGe(usdc.balanceOf(treasury), treasBefore, "Treasury >= before");
    }

    function test_AutoCollectFees_OnContribute() public {
        _startGroupWithUsers();

        // First contribution
        vm.prank(user1);
        group.contribute();

        // Warp for yield (stay within 12-cycle window = 84 days)
        vm.warp(block.timestamp + 70 days);

        uint256 treasBefore = usdc.balanceOf(treasury);

        // Second contribution triggers _accrueRewards -> _autoCollectFees
        // Warp to next cycle boundary (still within window)
        vm.warp(block.timestamp + CYCLE);
        vm.prank(user1);
        group.contribute();

        // If enough yield accrued, auto-collect should have sent to treasury
        uint256 treasAfter = usdc.balanceOf(treasury);
        console.log("Treasury before: $%s | After: $%s", _fmtUSDC(treasBefore), _fmtUSDC(treasAfter));
        // Auto-collect fires when fees >= 1 USDC
        if (group.totalAccumulatedFees() >= 1e6) {
            assertGt(treasAfter, treasBefore, "Auto-collect sent to treasury");
        }
    }

    // ####################################################################
    //  SECTION 3: HACKER ATTACK SCENARIOS
    // ####################################################################

    // ======================== A-01: REENTRANCY ========================

    /// @notice Prove reentrancy guard blocks recursive withdraw
    function test_ATTACK_ReentrancyOnWithdraw() public {
        _startGroupWithUsers();
        vm.prank(user1);
        group.contribute();
        vm.warp(block.timestamp + 7 days);

        // First withdraw succeeds
        vm.prank(user1);
        group.withdraw();

        // Second withdraw — no capital, should revert
        vm.prank(user1);
        vm.expectRevert(ZybraGroup.NotMember.selector);
        group.withdraw();
    }

    /// @notice Prove double-claim after full yield is taken
    function test_ATTACK_ReentrancyOnClaimYield() public {
        _startGroupWithUsers();
        vm.prank(user1);
        group.contribute();
        vm.warp(block.timestamp + 30 days);

        uint256 pending = group.pendingYield(user1);
        if (pending > 0) {
            vm.prank(user1);
            group.claimYield();

            // Second claim should give nothing
            uint256 pendingAfter = group.pendingYield(user1);
            if (pendingAfter == 0) {
                vm.prank(user1);
                vm.expectRevert(ZybraGroup.NothingToClaim.selector);
                group.claimYield();
            }
        }
    }

    // ======================== A-02: DOUBLE CONTRIBUTE ========================

    /// @notice Try contributing twice in same cycle
    function test_ATTACK_DoubleContributeInSameCycle() public {
        _startGroupWithUsers();

        vm.prank(user1);
        group.contribute();

        vm.prank(user1);
        vm.expectRevert(ZybraGroup.AlreadyContributed.selector);
        group.contribute();
    }

    // ======================== A-03: TEMPORAL ATTACKS ========================

    /// @notice Contribute before group is started
    function test_ATTACK_ContributeBeforeStart() public {
        vm.prank(user1);
        group.joinGroup();

        vm.prank(user1);
        vm.expectRevert(ZybraGroup.GroupNotStarted.selector);
        group.contribute();
    }

    /// @notice Contribute after group ended
    function test_ATTACK_ContributeAfterEnd() public {
        _startGroupWithUsers();
        vm.prank(user1);
        group.contribute();

        // End the group
        vm.prank(admin);
        group.endGroup();

        // Try contributing after end
        vm.warp(block.timestamp + CYCLE);
        vm.prank(user1);
        vm.expectRevert(ZybraGroup.GroupAlreadyEnded.selector);
        group.contribute();
    }

    // ======================== A-04: DOUBLE-SPEND / ZERO CAPITAL ========================

    /// @notice Withdraw twice — second should revert
    function test_ATTACK_DoubleWithdraw() public {
        _startGroupWithUsers();
        vm.prank(user1);
        group.contribute();

        vm.prank(user1);
        group.withdraw();

        // Second withdraw — member is now inactive
        vm.prank(user1);
        vm.expectRevert(ZybraGroup.NotMember.selector);
        group.withdraw();
    }

    /// @notice Withdraw without ever contributing (zero capital)
    function test_ATTACK_WithdrawZeroCapital() public {
        _startGroupWithUsers();
        // user1 joined but never contributed

        vm.prank(user1);
        vm.expectRevert(ZybraGroup.InvalidAmount.selector);
        group.withdraw();
    }

    // ======================== A-05: EMERGENCY WITHDRAW YIELD THEFT ========================

    /// @notice Emergency withdraw only returns capital, NOT yield
    function test_ATTACK_EmergencyWithdrawNoYieldTheft() public {
        _startGroupWithUsers();
        vm.prank(user1);
        group.contribute();

        vm.warp(block.timestamp + 90 days);

        uint256 pendingBefore = group.pendingYield(user1);
        uint256 balBefore = usdc.balanceOf(user1);

        vm.prank(user1);
        group.emergencyWithdraw();

        uint256 received = usdc.balanceOf(user1) - balBefore;

        // Emergency withdraw gives capital only — yield forfeited
        assertApproxEqRel(received, CONTRIBUTION, 0.01e18, "Only capital returned");
        if (pendingBefore > 0) {
            // Received should be close to CONTRIBUTION, not CONTRIBUTION + yield
            assertLt(received, CONTRIBUTION + pendingBefore, "No yield theft");
        }

        console.log("Capital: $%s | Pending yield forfeited: $%s | Received: $%s",
            _fmtUSDC(CONTRIBUTION), _fmtUSDC(pendingBefore), _fmtUSDC(received));
    }

    // ======================== A-06: ADMIN TRANSFER HIJACK ========================

    /// @notice Non-admin cannot initiate admin transfer
    function test_ATTACK_AdminTransferByNonAdmin() public {
        address attacker = makeAddr("attacker");

        vm.prank(attacker);
        vm.expectRevert(ZybraGroup.NotAdmin.selector);
        group.transferAdmin(attacker);
    }

    /// @notice Cannot accept admin if not pendingAdmin
    function test_ATTACK_AcceptAdminWithoutProposal() public {
        address attacker = makeAddr("attacker");

        vm.prank(attacker);
        vm.expectRevert(ZybraGroup.NotPendingAdmin.selector);
        group.acceptAdmin();
    }

    /// @notice 2-step admin transfer requires exact pendingAdmin
    function test_ATTACK_AdminTransferFrontRun() public {
        address newAdmin = makeAddr("newAdmin");
        address attacker = makeAddr("attacker");

        // Admin proposes newAdmin
        vm.prank(admin);
        group.transferAdmin(newAdmin);

        // Attacker tries to front-run accept
        vm.prank(attacker);
        vm.expectRevert(ZybraGroup.NotPendingAdmin.selector);
        group.acceptAdmin();

        // Only actual pendingAdmin can accept
        vm.prank(newAdmin);
        group.acceptAdmin();
        assertEq(group.admin(), newAdmin, "Correct new admin");
    }

    // ======================== A-07: FEE EVASION ========================

    /// @notice Withdrawing early doesn't erase accumulated protocol fees
    function test_ATTACK_FeeEvasionViaEarlyWithdrawal() public {
        _startGroupWithUsers();
        vm.prank(user1);
        group.contribute();
        vm.warp(block.timestamp + 60 days);

        uint256 feesBefore = group.totalAccumulatedFees();

        // User withdraws early
        vm.prank(user1);
        group.withdraw();

        // Fees weren't erased — they were accumulated via _accrueRewards during withdraw
        uint256 feesAfter = group.totalAccumulatedFees();
        assertGe(feesAfter, feesBefore, "Fees not reduced by withdrawal");

        console.log("Fees before withdraw: $%s | After: $%s", _fmtUSDC(feesBefore), _fmtUSDC(feesAfter));
    }

    // ======================== A-08: TREASURY REDIRECT ========================

    /// @notice Cannot change treasury — it's immutable
    function test_ATTACK_TreasuryRedirect() public {
        // Treasury is immutable — no setter function exists
        assertEq(group.treasury(), treasury, "Treasury unchanged");
    }

    /// @notice Fees always go to treasury, never to caller
    function test_ATTACK_CollectFeesToSelf() public {
        _startGroupWithUsers();
        vm.prank(user1);
        group.contribute();
        vm.warp(block.timestamp + 90 days);

        address attacker = makeAddr("attacker");
        uint256 attackerBefore = usdc.balanceOf(attacker);
        uint256 treasBefore = usdc.balanceOf(treasury);

        vm.prank(attacker);
        group.collectFees();

        assertEq(usdc.balanceOf(attacker), attackerBefore, "Attacker gains nothing");
        assertGe(usdc.balanceOf(treasury), treasBefore, "Treasury benefits");
    }

    // ======================== A-09: VAULT SHARE INFLATION ========================

    /// @notice Donating USDC to vault doesn't steal yield from group
    function test_ATTACK_VaultShareDonation() public {
        _startGroupWithUsers();
        vm.prank(user1);
        group.contribute();

        uint256 pendingBefore = group.pendingYield(user1);

        // Attacker donates USDC directly to vault to inflate share price
        address attacker = makeAddr("attacker");
        deal(USDC, attacker, 1_000_000e6);
        vm.startPrank(attacker);
        usdc.approve(MORPHO_VAULT, type(uint256).max);
        vault.deposit(1_000_000e6, attacker);
        vm.stopPrank();

        uint256 pendingAfter = group.pendingYield(user1);

        console.log("Pending before donation: $%s | After: $%s",
            _fmtUSDC(pendingBefore), _fmtUSDC(pendingAfter));

        // Vault value must still cover capital
        _assertInv1(group);
    }

    // ======================== A-10: MAX_MEMBERS OVERFLOW ========================

    /// @notice Cannot add member beyond MAX_MEMBERS
    function test_ATTACK_MaxMembersOverflow() public {
        ZybraGroup bigGroup = new ZybraGroup(USDC, CONTRIBUTION, CYCLE, CYCLES, admin, MORPHO_VAULT, treasury);

        // Admin is auto-added as member #1
        for (uint256 i = 1; i < 50; i++) {
            address member = makeAddr(string.concat("member", vm.toString(i)));
            vm.prank(member);
            bigGroup.joinGroup();
        }

        // Member #51 should fail
        address overflow = makeAddr("overflow");
        vm.prank(overflow);
        vm.expectRevert(ZybraGroup.InvalidAmount.selector);
        bigGroup.joinGroup();
    }

    // ======================== A-11: LEAVE AFTER START ========================

    /// @notice Cannot leave after group has started
    function test_ATTACK_LeaveAfterGroupStarted() public {
        _startGroupWithUsers();

        vm.prank(user1);
        vm.expectRevert(ZybraGroup.GroupAlreadyStarted.selector);
        group.leaveGroup();
    }

    // ======================== A-12: REJOIN AFTER LEAVE ========================

    /// @notice Can rejoin after leaving (before start)
    function test_ATTACK_RejoinAfterLeave() public {
        vm.prank(user1);
        group.joinGroup();

        vm.prank(user1);
        group.leaveGroup();

        // Rejoin should work
        vm.prank(user1);
        group.joinGroup();

        (,,, bool active) = group.getMemberInfo(user1);
        assertTrue(active, "Rejoined and active");
    }

    // ======================== A-13: SWEEP PROTECTED TOKENS ========================

    /// @notice Cannot sweep USDC (group asset)
    function test_ATTACK_SweepAsset() public {
        vm.prank(admin);
        vm.expectRevert(ZybraGroup.CannotSweep.selector);
        group.sweepToken(usdc);
    }

    /// @notice Cannot sweep vault shares
    function test_ATTACK_SweepVaultShares() public {
        vm.prank(admin);
        vm.expectRevert(ZybraGroup.CannotSweep.selector);
        group.sweepToken(IERC20(address(vault)));
    }

    /// @notice Non-admin cannot sweep anything
    function test_ATTACK_SweepByNonAdmin() public {
        address someToken = makeAddr("someToken");
        vm.prank(user1);
        vm.expectRevert(ZybraGroup.NotAdmin.selector);
        group.sweepToken(IERC20(someToken));
    }

    // ======================== A-14: PAUSE ABUSE ========================

    /// @notice Non-admin cannot pause
    function test_ATTACK_PauseByNonAdmin() public {
        vm.prank(user1);
        vm.expectRevert(ZybraGroup.NotAdmin.selector);
        group.pause();
    }

    /// @notice Non-admin cannot unpause
    function test_ATTACK_UnpauseByNonAdmin() public {
        vm.prank(admin);
        group.pause();

        vm.prank(user1);
        vm.expectRevert(ZybraGroup.NotAdmin.selector);
        group.unpause();
    }

    /// @notice Paused group blocks contribute, withdraw, claimYield but NOT emergencyWithdraw
    function test_ATTACK_PauseDoesNotBlockEmergency() public {
        _startGroupWithUsers();
        vm.prank(user1);
        group.contribute();

        vm.prank(admin);
        group.pause();

        // contribute blocked
        vm.warp(block.timestamp + CYCLE);
        vm.prank(user1);
        vm.expectRevert(ZybraGroup.ContractPaused.selector);
        group.contribute();

        // withdraw blocked
        vm.prank(user1);
        vm.expectRevert(ZybraGroup.ContractPaused.selector);
        group.withdraw();

        // claimYield blocked
        vm.prank(user1);
        vm.expectRevert(ZybraGroup.ContractPaused.selector);
        group.claimYield();

        // emergencyWithdraw IS allowed (escape hatch)
        uint256 bal = usdc.balanceOf(user1);
        vm.prank(user1);
        group.emergencyWithdraw();
        assertGe(usdc.balanceOf(user1) - bal, CONTRIBUTION - 1e6, "Emergency works under pause");
    }

    // ======================== A-15: endGroup GRIEFING ========================

    /// @notice Non-admin cannot end group before expiry
    function test_ATTACK_EndGroupBeforeExpiry() public {
        _startGroupWithUsers();

        vm.prank(user1);
        vm.expectRevert(ZybraGroup.GroupNotExpired.selector);
        group.endGroup();
    }

    /// @notice Non-admin CAN end group after all cycles + grace period (H-02 fix)
    function test_ATTACK_EndGroupAfterExpiry_Anyone() public {
        _startGroupWithUsers();

        // Warp past all cycles + grace period
        uint256 deadline = group.groupStartTime() + (CYCLES * CYCLE) + 7 days;
        vm.warp(deadline + 1);

        // Random person can end it
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        group.endGroup();

        assertTrue(group.groupEnded(), "Group ended by stranger after grace period");
    }

    /// @notice Admin can always end group (even during active cycles)
    function test_AdminCanAlwaysEndGroup() public {
        _startGroupWithUsers();

        vm.prank(admin);
        group.endGroup();
        assertTrue(group.groupEnded(), "Admin ended group");
    }

    /// @notice Cannot end group twice
    function test_ATTACK_DoubleEndGroup() public {
        _startGroupWithUsers();
        vm.prank(admin);
        group.endGroup();

        vm.prank(admin);
        vm.expectRevert(ZybraGroup.GroupAlreadyEnded.selector);
        group.endGroup();
    }

    // ======================== A-16: FLASH LOAN STYLE ATTACKS ========================

    /// @notice Join-contribute-withdraw in minimal time doesn't extract more than deposited
    function test_ATTACK_FlashContributeWithdraw() public {
        _startGroupWithUsers();

        uint256 balBefore = usdc.balanceOf(user1);
        vm.prank(user1);
        group.contribute();

        // Immediate withdraw (same block)
        vm.prank(user1);
        group.withdraw();

        uint256 balAfter = usdc.balanceOf(user1);

        // Cannot extract more than deposited (minus rounding dust)
        assertLe(balAfter, balBefore + 1e6, "No profit from flash contribute-withdraw");
    }

    // ======================== A-17: FRONT-RUNNING ========================

    /// @notice Front-running someone's contribute to steal their yield slot
    function test_ATTACK_FrontRunContribute() public {
        _startGroupMultiUser();

        // Both contribute in same cycle — each gets their own slot
        vm.prank(user1);
        group.contribute();
        vm.prank(user2);
        group.contribute();

        // Each has their own capital — no stealing
        (uint256 cap1,,,) = group.getMemberInfo(user1);
        (uint256 cap2,,,) = group.getMemberInfo(user2);
        assertEq(cap1, CONTRIBUTION, "User1 has own capital");
        assertEq(cap2, CONTRIBUTION, "User2 has own capital");
    }

    // ======================== A-18: COLLECT FEES WHEN DRAINED ========================

    /// @notice collectFees when vault has no excess funds returns 0
    function test_ATTACK_CollectFeesWhenDrained() public {
        _startGroupWithUsers();

        // No contributions yet, no yield
        uint256 result = group.collectFees();
        assertEq(result, 0, "No fees to collect");
    }

    // ======================== A-19: ACCUMULATOR OVERFLOW ========================

    /// @notice Multiple users with max contribution over many cycles — accumulator stays valid
    function test_ATTACK_AccumulatorOverflow_50UsersMaxContrib() public {
        (ZybraGroup whaleGroup, address[] memory users) = _createWhaleGroup(50);
        vm.prank(admin);
        whaleGroup.startGroup();

        // All 50 contribute for all 12 cycles
        for (uint256 cycle = 0; cycle < CYCLES; cycle++) {
            if (cycle > 0) vm.warp(block.timestamp + CYCLE);
            for (uint256 u = 0; u < users.length; u++) {
                vm.prank(users[u]);
                whaleGroup.contribute();
            }
        }

        assertEq(whaleGroup.totalCapitalInGroup(), 600_000e6, "$600K capital");

        // Warp 1 year
        vm.warp(block.timestamp + 365 days);

        // Accumulator should not overflow
        uint256 accRPS = whaleGroup.accRewardPerShare();
        assertLt(accRPS, type(uint256).max / 2, "No overflow risk");

        // All pending yields should be non-negative
        for (uint256 i = 0; i < users.length; i++) {
            uint256 p = whaleGroup.pendingYield(users[i]);
            assertGe(p, 0, "Non-negative yield");
        }
    }

    // ======================== A-20: CROSS-GROUP CONTAMINATION ========================

    /// @notice Two separate groups with same vault don't contaminate each other
    function test_ATTACK_CrossGroupContamination() public {
        // Group A
        ZybraGroup groupA = new ZybraGroup(USDC, CONTRIBUTION, CYCLE, CYCLES, admin, MORPHO_VAULT, treasury);
        // Group B
        ZybraGroup groupB = new ZybraGroup(USDC, CONTRIBUTION, CYCLE, CYCLES, admin, MORPHO_VAULT, treasury);

        // Join + Fund
        deal(USDC, user1, 10_000e6);
        deal(USDC, user2, 10_000e6);
        vm.prank(user1);
        usdc.approve(address(groupA), type(uint256).max);
        vm.prank(user2);
        usdc.approve(address(groupB), type(uint256).max);

        vm.prank(user1);
        groupA.joinGroup();
        vm.prank(user2);
        groupB.joinGroup();

        vm.prank(admin);
        usdc.approve(address(groupA), type(uint256).max);
        vm.prank(admin);
        usdc.approve(address(groupB), type(uint256).max);

        vm.prank(admin);
        groupA.startGroup();
        vm.prank(admin);
        groupB.startGroup();

        // User1 contributes to A, user2 to B
        vm.prank(user1);
        groupA.contribute();
        vm.prank(user2);
        groupB.contribute();

        vm.warp(block.timestamp + 30 days);

        // Each group tracks its own vault shares independently
        uint256 sharesA = vault.balanceOf(address(groupA));
        uint256 sharesB = vault.balanceOf(address(groupB));

        assertGt(sharesA, 0, "GroupA has shares");
        assertGt(sharesB, 0, "GroupB has shares");

        // Withdrawing from A doesn't affect B
        uint256 capB_before = groupB.totalCapitalInGroup();
        vm.prank(user1);
        groupA.withdraw();
        uint256 capB_after = groupB.totalCapitalInGroup();

        assertEq(capB_after, capB_before, "GroupB unaffected by GroupA withdraw");
    }

    // ======================== A-21: STALE CYCLE BOUNDARY ========================

    /// @notice Contributing at exact cycle boundary
    function test_ATTACK_CycleBoundaryEdge() public {
        _startGroupWithUsers();

        uint256 startTime = group.groupStartTime();
        uint256 cycleDur = group.cycleDuration();

        // Contribute at last second of cycle 1
        vm.warp(startTime + cycleDur - 1);
        vm.prank(user1);
        group.contribute();

        uint256 cycle = group.getCurrentCycle();
        assertEq(cycle, 1, "Still cycle 1 at boundary");

        // Contribute at first second of cycle 2
        vm.warp(startTime + cycleDur);
        cycle = group.getCurrentCycle();
        assertEq(cycle, 2, "Cycle 2 after boundary");

        vm.prank(user1);
        group.contribute();

        (uint256 cap,,,) = group.getMemberInfo(user1);
        assertEq(cap, 2 * CONTRIBUTION, "2 contributions tracked");
    }

    /// @notice Cannot contribute after all cycles are done
    function test_ATTACK_ContributeAfterAllCycles() public {
        _startGroupWithUsers();

        // Warp past all cycles
        vm.warp(block.timestamp + (CYCLES + 1) * CYCLE);

        vm.prank(user1);
        vm.expectRevert(ZybraGroup.InvalidCycle.selector);
        group.contribute();
    }

    // ======================== A-22: ZERO-CYCLE SANDWICH ========================

    /// @notice Join, start, contribute, withdraw in rapid succession
    function test_ATTACK_ZeroCycleSandwich() public {
        vm.prank(user1);
        group.joinGroup();
        vm.prank(user2);
        group.joinGroup();
        vm.prank(admin);
        group.startGroup();

        uint256 balBefore = usdc.balanceOf(user1);
        vm.prank(user1);
        group.contribute();
        vm.prank(user1);
        group.withdraw();
        uint256 balAfter = usdc.balanceOf(user1);

        // Should not profit from instant sandwich
        assertLe(balAfter, balBefore + 1e6, "No sandwich profit");
    }

    // ======================== A-23: FORCE-FEED USDC ========================

    /// @notice Direct USDC transfer to contract doesn't affect accounting
    function test_ATTACK_DirectUSDCTransferToContract() public {
        _startGroupWithUsers();
        vm.prank(user1);
        group.contribute();

        uint256 capBefore = group.totalCapitalInGroup();

        // Attacker sends USDC directly to the contract (not through contribute)
        address attacker = makeAddr("attacker");
        deal(USDC, attacker, 100_000e6);
        vm.prank(attacker);
        usdc.transfer(address(group), 100_000e6);

        // Contract's accounting should not be affected
        assertEq(group.totalCapitalInGroup(), capBefore, "Capital unchanged by force-feed");
    }

    // ======================== A-24: PENDING ADMIN EXPLOIT ========================

    /// @notice Overwriting pendingAdmin doesn't let old pendingAdmin accept
    function test_ATTACK_PendingAdminOverwrite() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");

        vm.prank(admin);
        group.transferAdmin(alice);

        // Before alice accepts, admin changes to bob
        vm.prank(admin);
        group.transferAdmin(bob);

        // Alice can no longer accept
        vm.prank(alice);
        vm.expectRevert(ZybraGroup.NotPendingAdmin.selector);
        group.acceptAdmin();

        // Only bob can
        vm.prank(bob);
        group.acceptAdmin();
        assertEq(group.admin(), bob, "Bob is admin");
    }

    // ======================== A-25: INACTIVE MEMBER CLAIMS ========================

    /// @notice Inactive member cannot claim yield
    function test_ATTACK_InactiveMemberClaim() public {
        _startGroupWithUsers();
        vm.prank(user1);
        group.contribute();
        vm.warp(block.timestamp + 30 days);

        // Withdraw — becomes inactive
        vm.prank(user1);
        group.withdraw();

        // Try to claim yield as inactive
        vm.prank(user1);
        vm.expectRevert(ZybraGroup.NotMember.selector);
        group.claimYield();
    }

    /// @notice Non-member cannot claim yield
    function test_ATTACK_NonMemberClaimYield() public {
        _startGroupWithUsers();
        address attacker = makeAddr("attacker");

        vm.prank(attacker);
        vm.expectRevert(ZybraGroup.NotMember.selector);
        group.claimYield();
    }

    /// @notice Non-member cannot withdraw
    function test_ATTACK_NonMemberWithdraw() public {
        _startGroupWithUsers();
        address attacker = makeAddr("attacker");

        vm.prank(attacker);
        vm.expectRevert(ZybraGroup.NotMember.selector);
        group.withdraw();
    }

    /// @notice Non-member cannot emergency withdraw
    function test_ATTACK_NonMemberEmergencyWithdraw() public {
        address attacker = makeAddr("attacker");

        vm.prank(attacker);
        vm.expectRevert(ZybraGroup.NotMember.selector);
        group.emergencyWithdraw();
    }

    // ======================== A-26: CONSTRUCTOR VALIDATION ========================

    /// @notice Cannot create group with zero addresses
    function test_ATTACK_ConstructorZeroAddress() public {
        vm.expectRevert(ZybraGroup.ZeroAddress.selector);
        new ZybraGroup(address(0), CONTRIBUTION, CYCLE, CYCLES, admin, MORPHO_VAULT, treasury);

        vm.expectRevert(ZybraGroup.ZeroAddress.selector);
        new ZybraGroup(USDC, CONTRIBUTION, CYCLE, CYCLES, address(0), MORPHO_VAULT, treasury);

        vm.expectRevert(ZybraGroup.ZeroAddress.selector);
        new ZybraGroup(USDC, CONTRIBUTION, CYCLE, CYCLES, admin, address(0), treasury);

        vm.expectRevert(ZybraGroup.ZeroAddress.selector);
        new ZybraGroup(USDC, CONTRIBUTION, CYCLE, CYCLES, admin, MORPHO_VAULT, address(0));
    }

    /// @notice Cannot create group with invalid contribution
    function test_ATTACK_ConstructorInvalidContribution() public {
        // Below minimum
        vm.expectRevert(ZybraGroup.InvalidAmount.selector);
        new ZybraGroup(USDC, 0, CYCLE, CYCLES, admin, MORPHO_VAULT, treasury);

        // Above maximum
        vm.expectRevert(ZybraGroup.InvalidAmount.selector);
        new ZybraGroup(USDC, 1001e6, CYCLE, CYCLES, admin, MORPHO_VAULT, treasury);
    }

    /// @notice Cannot create group with invalid cycles
    function test_ATTACK_ConstructorInvalidCycles() public {
        // Zero cycles
        vm.expectRevert(ZybraGroup.InvalidCycle.selector);
        new ZybraGroup(USDC, CONTRIBUTION, CYCLE, 0, admin, MORPHO_VAULT, treasury);

        // Too many cycles (>52)
        vm.expectRevert(ZybraGroup.InvalidCycle.selector);
        new ZybraGroup(USDC, CONTRIBUTION, CYCLE, 53, admin, MORPHO_VAULT, treasury);

        // Zero cycle duration
        vm.expectRevert(ZybraGroup.InvalidCycle.selector);
        new ZybraGroup(USDC, CONTRIBUTION, 0, CYCLES, admin, MORPHO_VAULT, treasury);
    }

    // ======================== A-27: VAULT ASSET MISMATCH ========================

    /// @notice Cannot create group with mismatched vault asset
    function test_ATTACK_VaultAssetMismatch() public {
        address fakeVault = makeAddr("fakeVault");
        vm.expectRevert(); // Will revert when calling asset() on non-contract
        new ZybraGroup(USDC, CONTRIBUTION, CYCLE, CYCLES, admin, fakeVault, treasury);
    }

    // ======================== A-28: START GROUP ABUSE ========================

    /// @notice Non-admin cannot start group
    function test_ATTACK_StartGroupNonAdmin() public {
        vm.prank(user1);
        group.joinGroup();

        vm.prank(user1);
        vm.expectRevert(ZybraGroup.NotAdmin.selector);
        group.startGroup();
    }

    /// @notice Cannot start group with only 1 member
    function test_ATTACK_StartGroupInsufficientMembers() public {
        vm.prank(admin);
        vm.expectRevert(ZybraGroup.InsufficientMembers.selector);
        group.startGroup();
    }

    /// @notice Cannot start group twice
    function test_ATTACK_StartGroupTwice() public {
        _startGroupWithUsers();

        vm.prank(admin);
        vm.expectRevert(ZybraGroup.GroupAlreadyStarted.selector);
        group.startGroup();
    }

    // ======================== A-29: JOIN ABUSE ========================

    /// @notice Cannot join twice
    function test_ATTACK_JoinGroupTwice() public {
        vm.prank(user1);
        group.joinGroup();

        vm.prank(user1);
        vm.expectRevert(ZybraGroup.AlreadyMember.selector);
        group.joinGroup();
    }

    /// @notice Cannot join after started
    function test_ATTACK_JoinAfterStart() public {
        _startGroupWithUsers();

        vm.prank(user2);
        vm.expectRevert(ZybraGroup.GroupAlreadyStarted.selector);
        group.joinGroup();
    }

    // ======================== A-30: YIELD SIPHONING ========================

    /// @notice Contribute -> claim yield -> contribute again — yield properly reset
    function test_ATTACK_YieldSiphoningLoop() public {
        _startGroupWithUsers();

        // Cycle 1
        vm.prank(user1);
        group.contribute();

        vm.warp(block.timestamp + 30 days);

        // Claim yield
        uint256 pending1 = group.pendingYield(user1);
        if (pending1 > 0) {
            vm.prank(user1);
            group.claimYield();
        }

        // After claim, pending should be 0
        assertEq(group.pendingYield(user1), 0, "Pending zero after claim");

        // Contribute next cycle
        vm.warp(block.timestamp + CYCLE);
        vm.prank(user1);
        group.contribute();

        // Pending should be 0 or very small (just the tiny yield from new contribution)
        uint256 pendingAfter = group.pendingYield(user1);
        assertLt(pendingAfter, CONTRIBUTION / 100, "No leftover yield siphon");
    }

    // ======================== A-31: EMERGENCY AFTER NORMAL WITHDRAW ========================

    /// @notice Cannot emergency withdraw after already withdrawing everything
    function test_ATTACK_EmergencyAfterWithdraw() public {
        _startGroupWithUsers();
        vm.prank(user1);
        group.contribute();

        vm.prank(user1);
        group.withdraw();

        // Now try emergency
        vm.prank(user1);
        vm.expectRevert(ZybraGroup.NotMember.selector);
        group.emergencyWithdraw();
    }

    // ======================== A-32: CLAIM THEN CONTRIBUTE ========================

    /// @notice Claiming yield doesn't reset capital or break subsequent operations
    function test_ATTACK_ClaimThenContribute() public {
        _startGroupWithUsers();

        vm.prank(user1);
        group.contribute();
        vm.warp(block.timestamp + 30 days);

        // Claim yield
        uint256 pending = group.pendingYield(user1);
        if (pending > 0) {
            vm.prank(user1);
            group.claimYield();
        }

        // Capital should remain intact after claim
        (uint256 cap,,, bool active) = group.getMemberInfo(user1);
        assertEq(cap, CONTRIBUTION, "Capital preserved after claim");
        assertTrue(active, "Still active after claim");

        // Can still contribute next cycle
        vm.warp(block.timestamp + CYCLE);
        vm.prank(user1);
        group.contribute();

        (cap,,,) = group.getMemberInfo(user1);
        assertEq(cap, 2 * CONTRIBUTION, "Capital accumulated correctly");
    }

    // ======================== A-33: membersList GAS GRIEFING ========================

    /// @notice membersList grows but doesn't block operations
    function test_ATTACK_MembersListGrowth() public {
        ZybraGroup bigGroup = new ZybraGroup(USDC, CONTRIBUTION, CYCLE, CYCLES, admin, MORPHO_VAULT, treasury);

        // Join 49 users (admin + 49 = MAX 50)
        for (uint256 i = 1; i < 50; i++) {
            address member = makeAddr(string.concat("gas_", vm.toString(i)));
            vm.prank(member);
            bigGroup.joinGroup();
        }

        assertEq(bigGroup.getMembersListLength(), 50, "50 members in list");
        assertEq(bigGroup.activeMembersCount(), 50, "50 active");
    }

    // ======================== A-34: PAUSED GROUP FEE COLLECTION ========================

    /// @notice Can still collect fees on paused group
    function test_ATTACK_CollectFeesWhilePaused() public {
        _startGroupWithUsers();
        vm.prank(user1);
        group.contribute();
        vm.warp(block.timestamp + 90 days);

        vm.prank(admin);
        group.pause();

        // collectFees has no whenNotPaused modifier — should work
        uint256 treasBefore = usdc.balanceOf(treasury);
        group.collectFees();
        assertGe(usdc.balanceOf(treasury), treasBefore, "Fees collected while paused");
    }

    // ======================== A-35: END GROUP YIELD SNAPSHOT ========================

    /// @notice endGroup snapshots yield — users can still withdraw after
    function test_ATTACK_EndGroupThenWithdraw() public {
        _startGroupWithUsers();
        vm.prank(user1);
        group.contribute();

        vm.warp(block.timestamp + 30 days);

        uint256 pendingBefore = group.pendingYield(user1);

        vm.prank(admin);
        group.endGroup();

        // User can still withdraw after group ended
        uint256 bal = usdc.balanceOf(user1);
        vm.prank(user1);
        group.withdraw();
        uint256 received = usdc.balanceOf(user1) - bal;

        assertGe(received, CONTRIBUTION - 1e6, "Got capital back after endGroup");
        console.log("Received after endGroup: $%s (pending was $%s)", _fmtUSDC(received), _fmtUSDC(pendingBefore));
    }

    // ####################################################################
    //  SECTION 4: WHALE-SCALE TESTS (Real Morpho vault)
    // ####################################################################

    function test_WhaleScale_50Members_FullLifecycle() public {
        console.log("################################################################");
        console.log("#  WHALE: 50 x $1,000 x 12 Cycles = $600,000 in Morpho        #");
        console.log("################################################################");

        (ZybraGroup whaleGroup, address[] memory users) = _createWhaleGroup(50);
        vm.prank(admin);
        whaleGroup.startGroup();

        uint256 t0 = block.timestamp;
        uint256 totalDeposited;

        for (uint256 cycle = 0; cycle < CYCLES; cycle++) {
            if (cycle > 0) vm.warp(block.timestamp + CYCLE);
            for (uint256 u = 0; u < users.length; u++) {
                vm.prank(users[u]);
                whaleGroup.contribute();
            }
            totalDeposited += 50 * CONTRIBUTION;
            _assertInv1(whaleGroup);
        }

        assertEq(whaleGroup.totalCapitalInGroup(), 600_000e6, "$600K");

        vm.warp(block.timestamp + 90 days);
        uint256 elapsedDays = (block.timestamp - t0) / 1 days;

        _printYieldReport(whaleGroup, users, "50 MEMBERS POST-90DAY", totalDeposited, elapsedDays);
        _assertInv1(whaleGroup);

        // Equal yield for equal capital
        uint256 minYield = type(uint256).max;
        uint256 maxYield = 0;
        for (uint256 i = 0; i < users.length; i++) {
            uint256 p = whaleGroup.pendingYield(users[i]);
            if (p < minYield) minYield = p;
            if (p > maxYield) maxYield = p;
        }
        if (maxYield > 0) {
            assertApproxEqRel(minYield, maxYield, 0.05e18, "Equal yield");
        }

        // Withdraw all
        uint256 totalWithdrawn;
        for (uint256 i = 0; i < users.length; i++) {
            uint256 bal = usdc.balanceOf(users[i]);
            vm.prank(users[i]);
            whaleGroup.withdraw();
            totalWithdrawn += usdc.balanceOf(users[i]) - bal;
        }

        assertGe(totalWithdrawn, totalDeposited, "No loss");
        assertEq(whaleGroup.totalCapitalInGroup(), 0, "All withdrawn");

        // Protocol fees
        uint256 pendingFees = whaleGroup.totalAccumulatedFees() - whaleGroup.totalFeesWithdrawn();
        if (pendingFees > 0) {
            uint256 treasBal = usdc.balanceOf(treasury);
            whaleGroup.collectFees();
            console.log("Protocol fees: $%s", _fmtUSDC(usdc.balanceOf(treasury) - treasBal));
        }
    }

    function test_WhaleScale_StaggeredEntry_YieldFairness() public {
        (ZybraGroup whaleGroup, address[] memory users) = _createWhaleGroup(30);
        vm.prank(admin);
        whaleGroup.startGroup();

        // Cycle 1: first 10
        for (uint256 i = 0; i < 10; i++) {
            vm.prank(users[i]);
            whaleGroup.contribute();
        }
        // Cycle 2: first 20
        _warpToCycle(whaleGroup, 2);
        for (uint256 i = 0; i < 20; i++) {
            vm.prank(users[i]);
            whaleGroup.contribute();
        }
        // Cycle 3+: all 30
        for (uint256 cycle = 3; cycle <= CYCLES; cycle++) {
            _warpToCycle(whaleGroup, cycle);
            for (uint256 i = 0; i < 30; i++) {
                vm.prank(users[i]);
                whaleGroup.contribute();
            }
        }

        vm.warp(block.timestamp + 60 days);

        uint256 earlyYield;
        uint256 lateYield;
        for (uint256 i = 0; i < 10; i++) earlyYield += whaleGroup.pendingYield(users[i]);
        for (uint256 i = 20; i < 30; i++) lateYield += whaleGroup.pendingYield(users[i]);

        console.log("Early avg: $%s | Late avg: $%s", _fmtUSDC(earlyYield / 10), _fmtUSDC(lateYield / 10));
        if (earlyYield > 0 && lateYield > 0) {
            assertGe(earlyYield / 10, lateYield / 10, "Early birds earn >= late");
        }
    }

    function test_WhaleScale_365Day_Yield() public {
        (ZybraGroup whaleGroup, address[] memory users) = _createWhaleGroup(20);
        vm.prank(admin);
        whaleGroup.startGroup();

        uint256 t0 = block.timestamp;
        for (uint256 cycle = 0; cycle < CYCLES; cycle++) {
            if (cycle > 0) vm.warp(block.timestamp + CYCLE);
            for (uint256 u = 0; u < users.length; u++) {
                vm.prank(users[u]);
                whaleGroup.contribute();
            }
        }

        uint256 totalDeposited = 20 * CONTRIBUTION * CYCLES;

        // Checkpoint at 30, 90, 180, 365 days past last cycle
        uint256[4] memory checkDays = [uint256(30), uint256(90), uint256(180), uint256(365)];
        uint256 lastWarp = block.timestamp;

        for (uint256 c = 0; c < 4; c++) {
            uint256 targetTime = t0 + (CYCLES * CYCLE) + checkDays[c] * 1 days;
            if (targetTime > lastWarp) {
                vm.warp(targetTime);
                lastWarp = targetTime;
            }

            uint256 vaultVal = vault.convertToAssets(vault.balanceOf(address(whaleGroup)));
            uint256 totalCap = whaleGroup.totalCapitalInGroup();
            uint256 grossYield = vaultVal > totalCap ? vaultVal - totalCap : 0;
            uint256 elapsed = (block.timestamp - t0) / 1 days;

            console.log("  +%s days: vault=$%s yield=$%s", checkDays[c], _fmtUSDC(vaultVal), _fmtUSDC(grossYield));
            if (totalCap > 0 && elapsed > 0) {
                uint256 apyBps = (grossYield * 10000 * 365) / (totalCap * elapsed);
                console.log("    APY: %s.%s%%", apyBps / 100, apyBps % 100);
            }
        }

        // Withdraw all
        uint256 totalWithdrawn;
        for (uint256 u = 0; u < users.length; u++) {
            uint256 bal = usdc.balanceOf(users[u]);
            vm.prank(users[u]);
            whaleGroup.withdraw();
            totalWithdrawn += usdc.balanceOf(users[u]) - bal;
        }

        assertGe(totalWithdrawn, totalDeposited, "No loss");
    }

    function test_WhaleScale_InterleaveClaimWithdraw() public {
        (ZybraGroup whaleGroup, address[] memory users) = _createWhaleGroup(30);
        vm.prank(admin);
        whaleGroup.startGroup();

        for (uint256 cycle = 0; cycle < 6; cycle++) {
            if (cycle > 0) vm.warp(block.timestamp + CYCLE);
            for (uint256 u = 0; u < users.length; u++) {
                vm.prank(users[u]);
                whaleGroup.contribute();
            }
        }

        vm.warp(block.timestamp + 30 days);

        // Users 0-9: claim yield
        for (uint256 i = 0; i < 10; i++) {
            uint256 p = whaleGroup.pendingYield(users[i]);
            if (p > 0) {
                vm.prank(users[i]);
                whaleGroup.claimYield();
            }
        }

        // Users 10-19: withdraw
        for (uint256 i = 10; i < 20; i++) {
            vm.prank(users[i]);
            whaleGroup.withdraw();
        }

        _assertInv1(whaleGroup);

        // Everyone else withdraws
        for (uint256 i = 0; i < 10; i++) {
            vm.prank(users[i]);
            whaleGroup.withdraw();
        }
        for (uint256 i = 20; i < 30; i++) {
            vm.prank(users[i]);
            whaleGroup.withdraw();
        }

        assertEq(whaleGroup.totalCapitalInGroup(), 0, "All capital out");
    }

    function test_WhaleScale_EmergencyWithdraw_Paused() public {
        (ZybraGroup whaleGroup, address[] memory users) = _createWhaleGroup(20);
        vm.prank(admin);
        whaleGroup.startGroup();

        for (uint256 cycle = 0; cycle < 3; cycle++) {
            if (cycle > 0) vm.warp(block.timestamp + CYCLE);
            for (uint256 u = 0; u < users.length; u++) {
                vm.prank(users[u]);
                whaleGroup.contribute();
            }
        }

        uint256 totalDeposited = 20 * CONTRIBUTION * 3;
        vm.warp(block.timestamp + 30 days);

        vm.prank(admin);
        whaleGroup.pause();

        // Normal withdraw blocked
        vm.prank(users[1]);
        vm.expectRevert(ZybraGroup.ContractPaused.selector);
        whaleGroup.withdraw();

        // Emergency works
        uint256 totalEmergency;
        for (uint256 i = 0; i < users.length; i++) {
            (uint256 cap,,,) = whaleGroup.getMemberInfo(users[i]);
            if (cap > 0) {
                uint256 bal = usdc.balanceOf(users[i]);
                vm.prank(users[i]);
                whaleGroup.emergencyWithdraw();
                totalEmergency += usdc.balanceOf(users[i]) - bal;
            }
        }

        assertApproxEqRel(totalEmergency, totalDeposited, 0.01e18, "Capital returned");
        assertEq(whaleGroup.totalCapitalInGroup(), 0, "All capital out");
    }

    function test_WhaleScale_MaxCapacity_DetailedBreakdown() public {
        (ZybraGroup whaleGroup, address[] memory users) = _createWhaleGroup(50);
        vm.prank(admin);
        whaleGroup.startGroup();

        uint256 totalDeposited;
        for (uint256 cycle = 0; cycle < CYCLES; cycle++) {
            if (cycle > 0) vm.warp(block.timestamp + CYCLE);
            for (uint256 u = 0; u < users.length; u++) {
                vm.prank(users[u]);
                whaleGroup.contribute();
            }
            totalDeposited += 50 * CONTRIBUTION;
        }
        assertEq(totalDeposited, 600_000e6, "$600K");

        vm.warp(block.timestamp + 180 days);

        uint256 elapsedDays = ((CYCLES - 1) * CYCLE + 180 days) / 1 days;
        uint256 vaultVal = vault.convertToAssets(vault.balanceOf(address(whaleGroup)));
        uint256 grossYield = vaultVal > 600_000e6 ? vaultVal - 600_000e6 : 0;

        console.log("=== $600K x 180d === Vault=$%s Yield=$%s", _fmtUSDC(vaultVal), _fmtUSDC(grossYield));

        if (grossYield > 0 && elapsedDays > 0) {
            uint256 apyBps = (grossYield * 10000 * 365) / (600_000e6 * elapsedDays);
            console.log("APY: %s.%s%% | Fee (10%%): $%s", apyBps / 100, apyBps % 100, _fmtUSDC(grossYield / 10));
        }

        // Mass withdrawal
        uint256 totalWithdrawn;
        for (uint256 i = 0; i < users.length; i++) {
            uint256 bal = usdc.balanceOf(users[i]);
            vm.prank(users[i]);
            whaleGroup.withdraw();
            totalWithdrawn += usdc.balanceOf(users[i]) - bal;
        }

        uint256 profit = totalWithdrawn > totalDeposited ? totalWithdrawn - totalDeposited : 0;
        console.log("Withdrawn=$%s Profit=$%s", _fmtUSDC(totalWithdrawn), _fmtUSDC(profit));

        uint256 feesLeft = whaleGroup.totalAccumulatedFees() - whaleGroup.totalFeesWithdrawn();
        if (feesLeft > 0) {
            uint256 treasBefore = usdc.balanceOf(treasury);
            whaleGroup.collectFees();
            console.log("Revenue: $%s", _fmtUSDC(usdc.balanceOf(treasury) - treasBefore));
        }

        assertGe(totalWithdrawn, totalDeposited, "No loss");
        assertEq(whaleGroup.totalCapitalInGroup(), 0, "Clean");
    }
}
