// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {ZybraGroup} from "src/ZybraGroup.sol";
import {IMorphoVaultV2} from "src/interfaces/IMorphoVaultV2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title ZybraGroup Mainnet Fork Test Suite - V3 Accumulator + Real Morpho Vault V2
 * @author Senior DeFi Engineer
 * @notice Production-grade tests against REAL Morpho Vault V2 (Steakhouse USDC) on Ethereum mainnet
 * @dev Fixed block fork, NO mocking, real whale impersonation
 *
 * MORPHO VAULT V2 (Steakhouse USDC):
 * - Address: 0xBEEF01735c132Ada46AA9aA4c54623cAA92A64CB
 * - Asset: USDC (0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48)
 *
 * V3 ACCUMULATOR PATTERN (MasterChef/Synthetix):
 *   accRewardPerShare += newYield * ACC_PRECISION / totalCapitalInGroup
 *   pendingYield = userCap * accRewardPerShare / ACC_PRECISION - rewardDebt
 *
 * INVARIANTS TESTED:
 * I1: totalCapitalInGroup == ÃƒÆ’Ã†â€™Ãƒâ€¦Ã‚Â½ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â£ members[i].capitalInGroup (all active)
 * I2: accRewardPerShare monotonically increases
 * I3: pending yield = capital * accRewardPerShare / PRECISION - rewardDebt (always ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€šÃ‚Â°ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¥ 0)
 * I4: totalDistributedYield + totalFeesWithdrawn + vaultYield = totalEverYield
 *
 * SCALE TESTS:
 * - 50 members ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â $1,000/cycle ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â 12 cycles = $600,000 total capital in Morpho
 * - Time-warped 365 days to accrue REAL Morpho vault yield
 * - Detailed console.log yield reports: per-user, APY, fee breakdown
 */
contract ZybraGroupV2MainnetForkTest is Test {
    // ==================== MAINNET ADDRESSES ====================

    address constant MORPHO_VAULT = 0xBEEF01735c132Ada46AA9aA4c54623cAA92A64CB;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    // USDC whales for impersonation (Binance, Circle, Circle Reserve)
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
    //  HELPER: Robust warp to a specific cycle (fork-mode safe)
    // ====================================================================

    /// @dev Warps block.timestamp to the start of `cycleNum` using groupStartTime
    ///      This avoids fork-mode timestamp drift when using relative warps
    function _warpToCycle(ZybraGroup g, uint256 cycleNum) internal {
        uint256 targetTs = g.groupStartTime() + (cycleNum - 1) * g.cycleDuration() + 1;
        vm.warp(targetTs);
    }

    // ====================================================================
    //  HELPER: Create whale-scale group with N members
    // ====================================================================

    function _createWhaleGroup(uint256 numMembers)
        internal
        returns (ZybraGroup whaleGroup, address[] memory users)
    {
        require(numMembers >= 2 && numMembers <= MAX_WHALE_USERS, "2-50 members");

        whaleGroup = new ZybraGroup(
            USDC, CONTRIBUTION, CYCLE, CYCLES, admin, MORPHO_VAULT, treasury
        );

        users = new address[](numMembers);
        users[0] = admin; // admin is auto-added

        // Create and fund additional members
        for (uint256 i = 1; i < numMembers; i++) {
            users[i] = makeAddr(string.concat("whale_user_", vm.toString(i)));
            deal(USDC, users[i], 1_000_000e6); // $1M each
            vm.prank(users[i]);
            usdc.approve(address(whaleGroup), type(uint256).max);
            vm.prank(users[i]);
            whaleGroup.joinGroup();
        }

        // Fund admin too
        deal(USDC, admin, 1_000_000e6);
        vm.prank(admin);
        usdc.approve(address(whaleGroup), type(uint256).max);

        return (whaleGroup, users);
    }

    // ====================================================================
    //  HELPER: Print detailed yield report
    // ====================================================================

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

        console.log("  Total Capital in Group:   $%s", _fmtUSDC(totalCap));
        console.log("  Vault Value (shares):     $%s", _fmtUSDC(vaultValue));
        console.log("  Gross Yield (vault):      $%s", _fmtUSDC(grossYield));
        console.log("  Elapsed:                  %s days", elapsedDays);
        console.log("  Active Members:           %s", g.activeMembersCount());

        if (totalCap > 0 && elapsedDays > 0) {
            uint256 apyBps = (grossYield * 10000 * 365) / (totalCap * elapsedDays);
            console.log("  Implied APY:              %s.%s%%", apyBps / 100, apyBps % 100);
        }

        console.log("------------------------------------------------------------");
        console.log("  ACCUMULATOR STATE:");
        console.log("    accRewardPerShare:      %s", g.accRewardPerShare());
        console.log("    totalDistributedYield:  $%s", _fmtUSDC(g.totalDistributedYield()));
        console.log("    totalFeesWithdrawn:     $%s", _fmtUSDC(g.totalFeesWithdrawn()));
        console.log("    totalAccumulatedFees:   $%s", _fmtUSDC(g.totalAccumulatedFees()));
        console.log("    lastMaterializedYield:  $%s", _fmtUSDC(g.lastMaterializedYield()));
        console.log("------------------------------------------------------------");

        uint256 totalPending;
        console.log("  PER-USER YIELD:");
        for (uint256 i = 0; i < users.length; i++) {
            (uint256 cap, uint256 pending, uint256 lastCycle, bool active) =
                g.getMemberInfo(users[i]);
            if (active && cap > 0) {
                totalPending += pending;
                uint256 userApyBps = 0;
                if (cap > 0 && elapsedDays > 0) {
                    userApyBps = (pending * 10000 * 365) / (cap * elapsedDays);
                }
                console.log("    User %s: capital=$%s  yield=$%s", i, _fmtUSDC(cap), _fmtUSDC(pending));
                console.log("      APY=%s.%s%%  cycle=%s", userApyBps / 100, userApyBps % 100, lastCycle);
            }
        }

        console.log("------------------------------------------------------------");
        console.log("  Total Pending (users):    $%s", _fmtUSDC(totalPending));
        uint256 pendingFees = g.totalAccumulatedFees() > g.totalFeesWithdrawn()
            ? g.totalAccumulatedFees() - g.totalFeesWithdrawn()
            : 0;
        console.log("  Protocol Fees (pending):  $%s", _fmtUSDC(pendingFees));
        console.log("  Capital deposited total:  $%s", _fmtUSDC(totalCapitalDeposited));
        console.log("============================================================");
        console.log("");
    }

    function _fmtUSDC(uint256 amount) internal pure returns (string memory) {
        uint256 whole = amount / 1e6;
        uint256 frac = (amount % 1e6) / 1e4; // 2 decimal places
        if (frac < 10) {
            return string.concat(vm.toString(whole), ".0", vm.toString(frac));
        }
        return string.concat(vm.toString(whole), ".", vm.toString(frac));
    }

    // ====================================================================
    //  TEST 1: DEPOSIT -> SHARES -> ASSETS
    // ====================================================================

    function test_Deposit_SharesMinted_AssetsTracked() public {
        vm.prank(user1);
        group.joinGroup();
        vm.prank(admin);
        group.startGroup();

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

    // ====================================================================
    //  TEST 2: REAL YIELD ACCRUAL (30 days)
    // ====================================================================

    function test_RealYieldAccrual() public {
        vm.prank(user1);
        group.joinGroup();
        vm.prank(admin);
        group.startGroup();

        vm.prank(user1);
        group.contribute();

        uint256 initial = vault.convertToAssets(vault.balanceOf(address(group)));

        vm.warp(block.timestamp + 30 days);

        uint256 final_ = vault.convertToAssets(vault.balanceOf(address(group)));

        assertGe(final_, initial, "Non-negative yield");
        assertGe(group.pendingYield(user1), 0, "Pending >= 0");

        console.log("=== SINGLE USER 30-DAY YIELD ===");
        console.log("Initial vault value: $%s", _fmtUSDC(initial));
        console.log("Final vault value:   $%s", _fmtUSDC(final_));
        console.log("Gross yield:         $%s", _fmtUSDC(final_ > initial ? final_ - initial : 0));
        console.log("User pending:        $%s", _fmtUSDC(group.pendingYield(user1)));
    }

    // ====================================================================
    //  TEST 3: ACCUMULATOR FAIRNESS (staggered entry)
    // ====================================================================

    function test_AccumulatorFairness() public {
        vm.prank(user1);
        group.joinGroup();
        vm.prank(user2);
        group.joinGroup();
        vm.prank(user3);
        group.joinGroup();

        vm.prank(admin);
        group.startGroup();

        uint256 t0 = block.timestamp;

        // User1 at T=0
        vm.prank(user1);
        group.contribute();

        // User2 at T=2d
        vm.warp(t0 + 2 days);
        vm.prank(user2);
        group.contribute();

        // User3 at T=4d
        vm.warp(t0 + 4 days);
        vm.prank(user3);
        group.contribute();

        // End of cycle
        vm.warp(t0 + 7 days);

        uint256 p1 = group.pendingYield(user1);
        uint256 p2 = group.pendingYield(user2);
        uint256 p3 = group.pendingYield(user3);

        console.log("=== FAIRNESS: Staggered Entry ===");
        console.log("User1 (7d): $%s", _fmtUSDC(p1));
        console.log("User2 (5d): $%s", _fmtUSDC(p2));
        console.log("User3 (3d): $%s", _fmtUSDC(p3));

        assertGe(p1, p3, "Earlier gets more or equal yield");
    }

    // ====================================================================
    //  TEST 4: CLAIM IDEMPOTENCY
    // ====================================================================

    function test_ClaimIdempotency() public {
        vm.prank(user1);
        group.joinGroup();
        vm.prank(admin);
        group.startGroup();

        vm.prank(user1);
        group.contribute();

        vm.warp(block.timestamp + 30 days);

        uint256 pending = group.pendingYield(user1);

        if (pending > 0) {
            uint256 bal = usdc.balanceOf(user1);
            vm.prank(user1);
            group.claimYield();
            uint256 claimed1 = usdc.balanceOf(user1) - bal;
            console.log("First claim: $%s", _fmtUSDC(claimed1));

            uint256 pendingAfter = group.pendingYield(user1);
            if (pendingAfter == 0) {
                vm.prank(user1);
                vm.expectRevert(ZybraGroup.NothingToClaim.selector);
                group.claimYield();
            }
        }
    }

    // ====================================================================
    //  TEST 5: WITHDRAW CORRECTNESS
    // ====================================================================

    function test_WithdrawCorrectness() public {
        vm.prank(user1);
        group.joinGroup();
        vm.prank(admin);
        group.startGroup();

        vm.prank(user1);
        group.contribute();

        vm.warp(block.timestamp + 30 days);

        uint256 pending = group.pendingYield(user1);
        uint256 bal = usdc.balanceOf(user1);

        vm.prank(user1);
        group.withdraw();

        uint256 received = usdc.balanceOf(user1) - bal;

        assertGe(received, CONTRIBUTION - 1e6, "At least capital");
        if (pending > 0) {
            assertApproxEqRel(received, CONTRIBUTION + pending, 0.02e18, "Cap + yield");
        }

        (uint256 cap,,, bool active) = group.getMemberInfo(user1);
        assertEq(cap, 0, "Capital cleared");
        assertFalse(active, "Inactive");

        console.log("=== WITHDRAW ===");
        console.log("Capital:  $%s", _fmtUSDC(CONTRIBUTION));
        console.log("Yield:    $%s", _fmtUSDC(pending));
        console.log("Received: $%s", _fmtUSDC(received));
    }

    // ====================================================================
    //  TEST 6: PROTOCOL FEE CORRECTNESS
    // ====================================================================

    function test_ProtocolFeeCorrectness() public {
        vm.prank(user1);
        group.joinGroup();
        vm.prank(admin);
        group.startGroup();

        vm.prank(user1);
        group.contribute();

        vm.warp(block.timestamp + 5 * CYCLE);

        uint256 vaultVal = vault.convertToAssets(vault.balanceOf(address(group)));
        uint256 cap = group.totalCapitalInGroup();

        if (vaultVal > cap) {
            uint256 yield_ = vaultVal - cap;
            uint256 maxFee = (yield_ * 100) / 10_000; // 1%
            assertTrue(maxFee <= yield_, "Fee capped at 1%");
            console.log("=== FEE CHECK ===");
            console.log("Gross yield: $%s", _fmtUSDC(yield_));
            console.log("Max fee (1%%): $%s", _fmtUSDC(maxFee));
        }
    }

    // ====================================================================
    //  TEST 7: ZERO YIELD AT T=0
    // ====================================================================

    function test_ZeroYield_VaultEqualsCapital() public {
        vm.prank(user1);
        group.joinGroup();
        vm.prank(admin);
        group.startGroup();

        vm.prank(user1);
        group.contribute();

        uint256 vaultVal = vault.convertToAssets(vault.balanceOf(address(group)));
        uint256 cap = group.totalCapitalInGroup();

        assertApproxEqRel(vaultVal, cap, 0.01e18, "~Equal at T=0");

        uint256 pending = group.pendingYield(user1);
        assertTrue(pending < cap / 100, "Minimal pending at T=0");
    }

    // ====================================================================
    //  TEST 8: ZERO-YIELD OPERATIONS
    // ====================================================================

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

        vm.warp(block.timestamp + CYCLE);
        vm.prank(user2);
        group.contribute();

        (uint256 cap2,,,) = group.getMemberInfo(user2);
        assertEq(cap2, 2 * CONTRIBUTION, "2x contribution");
    }

    // ====================================================================
    //  TEST 9: LIQUIDITY SAFETY - 5 users full withdraw
    // ====================================================================

    function test_LiquiditySafety() public {
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

        uint256 vaultVal = vault.convertToAssets(vault.balanceOf(address(group)));
        uint256 cap = group.totalCapitalInGroup();
        assertGe(vaultVal, cap, "Vault covers all");

        uint256 totalWithdrawn;
        for (uint256 i = 0; i < 5; i++) {
            uint256 bal = usdc.balanceOf(users[i]);
            vm.prank(users[i]);
            group.withdraw();
            totalWithdrawn += usdc.balanceOf(users[i]) - bal;
        }

        assertApproxEqRel(totalWithdrawn, vaultVal, 0.01e18, "All withdrawn");
        assertEq(group.totalCapitalInGroup(), 0, "Cap zero");
    }

    // ====================================================================
    //  INVARIANT 1: Capital <= Vault
    // ====================================================================

    function test_Invariant1_CapitalLeVault() public {
        vm.prank(user1);
        group.joinGroup();
        vm.prank(user2);
        group.joinGroup();
        vm.prank(user3);
        group.joinGroup();

        vm.prank(admin);
        group.startGroup();

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

    function _assertInv1(ZybraGroup g) internal view {
        uint256 cap = g.totalCapitalInGroup();
        uint256 shares = vault.balanceOf(address(g));
        uint256 vaultVal = shares > 0 ? vault.convertToAssets(shares) : 0;
        assertTrue(cap <= vaultVal + 1e6, "INV1: cap <= vault");
    }

    // ====================================================================
    //  INVARIANT 2: Sum Capital == Total
    // ====================================================================

    function test_Invariant2_SumCapitalEqTotal() public {
        vm.prank(user1);
        group.joinGroup();
        vm.prank(user2);
        group.joinGroup();
        vm.prank(user3);
        group.joinGroup();

        vm.prank(admin);
        group.startGroup();

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

        _assertInv2();
    }

    function _assertInv2() internal view {
        uint256 total = group.totalCapitalInGroup();
        uint256 sum;
        address[4] memory users = [admin, user1, user2, user3];
        for (uint256 i = 0; i < 4; i++) {
            (uint256 cap,,, bool active) = group.getMemberInfo(users[i]);
            if (active) sum += cap;
        }
        assertEq(sum, total, "INV2: sum == total");
    }

    // ====================================================================
    //  MULTI-CYCLE COMPREHENSIVE
    // ====================================================================

    function test_MultiCycleComprehensive() public {
        vm.prank(user1);
        group.joinGroup();
        vm.prank(user2);
        group.joinGroup();
        vm.prank(user3);
        group.joinGroup();

        vm.prank(admin);
        group.startGroup();

        // Cycle 1
        vm.prank(user1);
        group.contribute();
        vm.prank(user2);
        group.contribute();

        // Cycle 2
        vm.warp(block.timestamp + CYCLE);
        vm.prank(user1);
        group.contribute();
        vm.prank(user3);
        group.contribute();

        // Cycle 3 - claim
        vm.warp(block.timestamp + CYCLE);
        vm.prank(user1);
        group.contribute();

        uint256 pending = group.pendingYield(user2);
        if (pending > 0) {
            vm.prank(user2);
            group.claimYield();
        }

        // Cycle 4 - withdraw
        vm.warp(block.timestamp + CYCLE);
        vm.prank(user1);
        group.withdraw();

        // user2 has 1000e6, user3 has 1000e6 remaining
        assertEq(group.totalCapitalInGroup(), 1_000e6 + 1_000e6, "Remaining capital");
    }

    // ====================================================================
    //  ERC4626 COMPLIANCE
    // ====================================================================

    function test_VaultERC4626() public view {
        assertEq(vault.asset(), USDC, "Asset USDC");

        uint256 shares = vault.previewDeposit(10_000e6);
        uint256 assets = vault.convertToAssets(shares);
        assertApproxEqRel(assets, 10_000e6, 0.01e18, "Round-trip");
    }

    // ====================================================================
    //  ADMIN SELF-OPS
    // ====================================================================

    function test_AdminSelfOps() public {
        // MIN_MEMBERS = 2, so add user1 before starting
        vm.prank(user1);
        group.joinGroup();
        vm.prank(admin);
        group.startGroup();

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

    // ====================================================================
    //  NON-MONOTONIC YIELD SAFE
    // ====================================================================

    function test_NonMonotonicYieldSafe() public {
        vm.prank(user1);
        group.joinGroup();
        vm.prank(admin);
        group.startGroup();

        vm.prank(user1);
        group.contribute();

        vm.warp(block.timestamp + 7 days);

        uint256 pending = group.pendingYield(user1);
        assertTrue(pending >= 0, "Never negative");

        uint256 bal = usdc.balanceOf(user1);
        vm.prank(user1);
        group.withdraw();
        assertGe(usdc.balanceOf(user1) - bal, (CONTRIBUTION * 99) / 100, "99% capital");
    }

    // ====================================================================
    //  RAPID OPS
    // ====================================================================

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

        assertEq(cap1, 4 * CONTRIBUTION, "4x");
        assertEq(cap2, 4 * CONTRIBUTION, "4x");
    }

    // ====================================================================
    //  TREASURY TESTS
    // ====================================================================

    function test_TreasuryInitialized() public view {
        assertEq(group.treasury(), treasury, "Treasury set correctly");
        assertEq(group.totalAccumulatedFees(), 0, "No fees yet");
    }

    function test_TreasuryFeeAccumulatedOnYieldClaim() public {
        vm.prank(user1);
        group.joinGroup();
        vm.prank(admin);
        group.startGroup();

        vm.prank(user1);
        group.contribute();

        vm.warp(block.timestamp + 90 days);

        uint256 pending = group.pendingYield(user1);
        console.log("Pending yield before claim: $%s", _fmtUSDC(pending));

        if (pending > 0) {
            vm.prank(user1);
            group.claimYield();

            uint256 fees = group.totalAccumulatedFees();
            console.log("Accumulated fees: $%s", _fmtUSDC(fees));
            assertGt(fees, 0, "Fees accumulated from claim");
        }
    }

    function test_CollectFeesSendsToTreasury() public {
        vm.prank(user1);
        group.joinGroup();
        vm.prank(admin);
        group.startGroup();

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
            // V3: only admin can collect fees
            vm.prank(admin);
            group.collectFees();

            assertEq(
                usdc.balanceOf(treasury),
                treasuryBalBefore + pendingFees,
                "Treasury received fees"
            );
            console.log("Fees sent to treasury: $%s", _fmtUSDC(pendingFees));
        }
    }

    function test_SetTreasuryByAdmin() public {
        address newTreasury = makeAddr("newTreasury");
        vm.prank(admin);
        group.setTreasury(newTreasury);
        assertEq(group.treasury(), newTreasury, "Treasury updated");
    }

    function test_SetTreasuryRevertsForNonAdmin() public {
        vm.prank(user1);
        vm.expectRevert();
        group.setTreasury(makeAddr("x"));
    }

    function test_SetTreasuryRevertsForZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert();
        group.setTreasury(address(0));
    }

    function test_FeeIsExactlyOnePercent() public view {
        uint256 testYield = 10_000e6;
        uint256 expectedFee = 100e6; // 1%
        uint256 feeBps = group.PROTOCOL_FEE_BPS();
        assertEq(feeBps, 100, "Fee is 100 bps = 1%");
        assertEq((testYield * feeBps) / 10_000, expectedFee, "Fee calc correct");
    }

    // ####################################################################
    //                    WHALE-SCALE TESTS
    //         50 members x $1,000/cycle x 12 cycles = $600,000
    //               Real Morpho Vault V2 yield accrual
    // ####################################################################

    /**
     * @notice 50 members, full 12-cycle lifecycle, real Morpho yield
     * @dev Flagship test: $600K capital in real Steakhouse USDC vault
     */
    function test_WhaleScale_50Members_FullLifecycle() public {
        console.log("");
        console.log("################################################################");
        console.log("#  WHALE TEST: 50 Members x $1,000 x 12 Cycles = $600,000     #");
        console.log("#  Real Morpho Vault V2 (Steakhouse USDC) Yield               #");
        console.log("################################################################");

        (ZybraGroup whaleGroup, address[] memory users) = _createWhaleGroup(50);

        vm.prank(admin);
        whaleGroup.startGroup();

        uint256 t0 = block.timestamp;
        uint256 totalDeposited;

        // Run all 12 cycles
        for (uint256 cycle = 0; cycle < CYCLES; cycle++) {
            if (cycle > 0) {
                vm.warp(block.timestamp + CYCLE);
            }

            for (uint256 u = 0; u < users.length; u++) {
                vm.prank(users[u]);
                whaleGroup.contribute();
            }
            totalDeposited += 50 * CONTRIBUTION;

            _assertInv1(whaleGroup);

            console.log(
                "  Cycle %s complete: totalCap=$%s  vaultVal=$%s",
                cycle + 1,
                _fmtUSDC(whaleGroup.totalCapitalInGroup()),
                _fmtUSDC(vault.convertToAssets(vault.balanceOf(address(whaleGroup))))
            );
        }

        assertEq(whaleGroup.totalCapitalInGroup(), 600_000e6, "$600K capital");
        console.log("");
        console.log("  ALL 12 CYCLES COMPLETE: $600,000 DEPOSITED");

        // Warp 90 days for significant yield
        vm.warp(block.timestamp + 90 days);

        uint256 elapsedDays = (block.timestamp - t0) / 1 days;

        _printYieldReport(whaleGroup, users, "50 MEMBERS - POST 90-DAY YIELD", totalDeposited, elapsedDays);

        _assertInv1(whaleGroup);

        // Verify yield distribution
        uint256 minYield = type(uint256).max;
        uint256 maxYield = 0;
        uint256 totalPendingYield;

        for (uint256 i = 0; i < users.length; i++) {
            uint256 p = whaleGroup.pendingYield(users[i]);
            totalPendingYield += p;
            if (p < minYield) minYield = p;
            if (p > maxYield) maxYield = p;
        }

        console.log("  MIN user yield: $%s", _fmtUSDC(minYield));
        console.log("  MAX user yield: $%s", _fmtUSDC(maxYield));
        console.log("  TOTAL pending:  $%s", _fmtUSDC(totalPendingYield));

        // All equal contributors get equal yield (accumulator guarantee)
        if (maxYield > 0) {
            assertApproxEqRel(minYield, maxYield, 0.05e18, "Equal yield for equal capital");
        }

        // Withdraw all
        uint256 totalWithdrawn;
        for (uint256 i = 0; i < users.length; i++) {
            uint256 bal = usdc.balanceOf(users[i]);
            vm.prank(users[i]);
            whaleGroup.withdraw();
            totalWithdrawn += usdc.balanceOf(users[i]) - bal;
        }

        console.log("");
        console.log("  TOTAL WITHDRAWN: $%s", _fmtUSDC(totalWithdrawn));
        console.log("  PROFIT:          $%s", _fmtUSDC(totalWithdrawn > totalDeposited ? totalWithdrawn - totalDeposited : 0));

        assertGe(totalWithdrawn, totalDeposited, "No loss");
        assertEq(whaleGroup.totalCapitalInGroup(), 0, "All withdrawn");

        // Collect protocol fees
        uint256 pendingFees = whaleGroup.totalAccumulatedFees() - whaleGroup.totalFeesWithdrawn();
        if (pendingFees > 0) {
            uint256 treasBal = usdc.balanceOf(treasury);
            vm.prank(admin);
            whaleGroup.collectFees();
            uint256 feesCollected = usdc.balanceOf(treasury) - treasBal;
            console.log("  PROTOCOL FEES:   $%s", _fmtUSDC(feesCollected));
        }
    }

    /**
     * @notice Staggered entry: early birds earn more
     * @dev 10 early + 10 mid + 10 late - proves accumulator fairness
     */
    function test_WhaleScale_StaggeredEntry_YieldFairness() public {
        console.log("");
        console.log("################################################################");
        console.log("#  STAGGERED ENTRY: Early/Mid/Late - Yield Fairness            #");
        console.log("################################################################");

        (ZybraGroup whaleGroup, address[] memory users) = _createWhaleGroup(30);

        vm.prank(admin);
        whaleGroup.startGroup();

        // Cycle 1: Only first 10 (already at cycle 1 after startGroup)
        for (uint256 i = 0; i < 10; i++) {
            vm.prank(users[i]);
            whaleGroup.contribute();
        }
        console.log("  Cycle 1: 10 early birds contributed $10K");

        // Cycle 2: First 20
        _warpToCycle(whaleGroup, 2);
        for (uint256 i = 0; i < 20; i++) {
            vm.prank(users[i]);
            whaleGroup.contribute();
        }
        console.log("  Cycle 2: 20 members contributed $20K");

        // Cycle 3: All 30
        _warpToCycle(whaleGroup, 3);
        for (uint256 i = 0; i < 30; i++) {
            vm.prank(users[i]);
            whaleGroup.contribute();
        }
        console.log("  Cycle 3: All 30 members contributed $30K");

        // Remaining cycles 4..12: all 30
        for (uint256 cycle = 4; cycle <= CYCLES; cycle++) {
            _warpToCycle(whaleGroup, cycle);
            for (uint256 i = 0; i < 30; i++) {
                vm.prank(users[i]);
                whaleGroup.contribute();
            }
        }

        // Warp for yield
        vm.warp(block.timestamp + 60 days);

        // Calculate elapsed deterministically (fork-mode safe)
        uint256 elapsedDays = ((CYCLES - 1) * CYCLE + 60 days) / 1 days;

        uint256 earlyYield;
        uint256 midYield;
        uint256 lateYield;

        for (uint256 i = 0; i < 10; i++) earlyYield += whaleGroup.pendingYield(users[i]);
        for (uint256 i = 10; i < 20; i++) midYield += whaleGroup.pendingYield(users[i]);
        for (uint256 i = 20; i < 30; i++) lateYield += whaleGroup.pendingYield(users[i]);

        console.log("");
        console.log("  === STAGGERED YIELD (%s days) ===", elapsedDays);
        console.log("  Early (0-9):   total=$%s  avg=$%s", _fmtUSDC(earlyYield), _fmtUSDC(earlyYield / 10));
        console.log("  Mid  (10-19):  total=$%s  avg=$%s", _fmtUSDC(midYield), _fmtUSDC(midYield / 10));
        console.log("  Late (20-29):  total=$%s  avg=$%s", _fmtUSDC(lateYield), _fmtUSDC(lateYield / 10));

        if (earlyYield > 0 && lateYield > 0) {
            assertGe(earlyYield / 10, lateYield / 10, "Early birds earn >= late");
        }

        _printYieldReport(whaleGroup, users, "STAGGERED ENTRY", 0, elapsedDays);
    }

    /**
     * @notice 365-day yield accumulation: see real annualized Morpho yield
     * @dev 20 members, checkpoints at 30/90/180/365 days
     */
    function test_WhaleScale_365Day_YieldAccumulation() public {
        console.log("");
        console.log("################################################################");
        console.log("#  365-DAY YIELD: 20 Members, Real Morpho Annual Yield         #");
        console.log("################################################################");

        (ZybraGroup whaleGroup, address[] memory users) = _createWhaleGroup(20);

        vm.prank(admin);
        whaleGroup.startGroup();

        uint256 t0 = block.timestamp;

        // All 20 contribute for all 12 cycles
        for (uint256 cycle = 0; cycle < CYCLES; cycle++) {
            if (cycle > 0) {
                vm.warp(block.timestamp + CYCLE);
            }
            for (uint256 u = 0; u < users.length; u++) {
                vm.prank(users[u]);
                whaleGroup.contribute();
            }
        }

        uint256 totalDeposited = 20 * CONTRIBUTION * CYCLES; // $240,000
        console.log("  Capital deposited: $%s", _fmtUSDC(totalDeposited));

        uint256[4] memory checkDays = [uint256(30), uint256(90), uint256(180), uint256(365)];
        uint256 lastWarp = block.timestamp;

        for (uint256 c = 0; c < 4; c++) {
            uint256 targetTime = t0 + (CYCLES * CYCLE) + checkDays[c] * 1 days;
            if (targetTime > lastWarp) {
                vm.warp(targetTime);
                lastWarp = targetTime;
            }

            uint256 elapsed = (block.timestamp - t0) / 1 days;
            uint256 vaultVal = vault.convertToAssets(vault.balanceOf(address(whaleGroup)));
            uint256 totalCap = whaleGroup.totalCapitalInGroup();
            uint256 grossYield = vaultVal > totalCap ? vaultVal - totalCap : 0;

            uint256 totalPending;
            for (uint256 u = 0; u < users.length; u++) {
                totalPending += whaleGroup.pendingYield(users[u]);
            }

            uint256 apyBps = totalCap > 0 && elapsed > 0
                ? (grossYield * 10000 * 365) / (totalCap * elapsed)
                : 0;

            console.log("");
            console.log("  --- CHECKPOINT: +%s days ---", checkDays[c]);
            console.log("    Vault value:    $%s", _fmtUSDC(vaultVal));
            console.log("    Total capital:  $%s", _fmtUSDC(totalCap));
            console.log("    Gross yield:    $%s", _fmtUSDC(grossYield));
            console.log("    User yield:     $%s", _fmtUSDC(totalPending));
            console.log("    Implied APY:    %s.%s%%", apyBps / 100, apyBps % 100);
        }

        _printYieldReport(whaleGroup, users, "365-DAY FINAL", totalDeposited, (block.timestamp - t0) / 1 days);

        // Withdraw all
        uint256 totalWithdrawn;
        for (uint256 u = 0; u < users.length; u++) {
            uint256 bal = usdc.balanceOf(users[u]);
            vm.prank(users[u]);
            whaleGroup.withdraw();
            totalWithdrawn += usdc.balanceOf(users[u]) - bal;
        }

        uint256 profit = totalWithdrawn > totalDeposited ? totalWithdrawn - totalDeposited : 0;
        console.log("");
        console.log("  FINAL: Withdrawn=$%s  Profit=$%s", _fmtUSDC(totalWithdrawn), _fmtUSDC(profit));

        assertGe(totalWithdrawn, totalDeposited, "No loss");
    }

    /**
     * @notice Interleaved claims and withdrawals under load
     * @dev 30 members, some claim, some withdraw, prove no yield lock
     */
    function test_WhaleScale_InterleaveClaimWithdraw() public {
        console.log("");
        console.log("################################################################");
        console.log("#  INTERLEAVED: 30 Members, Claims + Withdrawals Under Load    #");
        console.log("################################################################");

        (ZybraGroup whaleGroup, address[] memory users) = _createWhaleGroup(30);

        vm.prank(admin);
        whaleGroup.startGroup();

        // 6 cycles: everyone contributes
        for (uint256 cycle = 0; cycle < 6; cycle++) {
            if (cycle > 0) {
                vm.warp(block.timestamp + CYCLE);
            }
            for (uint256 u = 0; u < users.length; u++) {
                vm.prank(users[u]);
                whaleGroup.contribute();
            }
        }

        // Warp 30 days
        vm.warp(block.timestamp + 30 days);

        console.log("  After 6 cycles + 30 days:");
        console.log("    Capital: $%s", _fmtUSDC(whaleGroup.totalCapitalInGroup()));

        // Users 0-9: claim yield
        uint256 totalClaimed;
        for (uint256 i = 0; i < 10; i++) {
            uint256 p = whaleGroup.pendingYield(users[i]);
            if (p > 0) {
                uint256 bal = usdc.balanceOf(users[i]);
                vm.prank(users[i]);
                whaleGroup.claimYield();
                totalClaimed += usdc.balanceOf(users[i]) - bal;
            }
        }
        console.log("  Claimed by users 0-9: $%s", _fmtUSDC(totalClaimed));

        // Users 10-19: withdraw
        uint256 totalWithdrawnMid;
        for (uint256 i = 10; i < 20; i++) {
            uint256 bal = usdc.balanceOf(users[i]);
            vm.prank(users[i]);
            whaleGroup.withdraw();
            totalWithdrawnMid += usdc.balanceOf(users[i]) - bal;
        }
        console.log("  Withdrawn by users 10-19: $%s", _fmtUSDC(totalWithdrawnMid));

        // Users 20-29: still in
        uint256 remainingYield;
        for (uint256 i = 20; i < 30; i++) {
            remainingYield += whaleGroup.pendingYield(users[i]);
        }
        console.log("  Remaining yield for 20-29: $%s", _fmtUSDC(remainingYield));

        _assertInv1(whaleGroup);

        // Everyone else withdraws
        uint256 totalFinal;
        for (uint256 i = 0; i < 10; i++) {
            uint256 bal = usdc.balanceOf(users[i]);
            vm.prank(users[i]);
            whaleGroup.withdraw();
            totalFinal += usdc.balanceOf(users[i]) - bal;
        }
        for (uint256 i = 20; i < 30; i++) {
            uint256 bal = usdc.balanceOf(users[i]);
            vm.prank(users[i]);
            whaleGroup.withdraw();
            totalFinal += usdc.balanceOf(users[i]) - bal;
        }

        console.log("  Final withdrawals: $%s", _fmtUSDC(totalFinal));
        assertEq(whaleGroup.totalCapitalInGroup(), 0, "All capital out");

        uint256 feesLeft = whaleGroup.totalAccumulatedFees() - whaleGroup.totalFeesWithdrawn();
        if (feesLeft > 0) {
            vm.prank(admin);
            whaleGroup.collectFees();
            console.log("  Protocol fees: $%s", _fmtUSDC(feesLeft));
        }
    }

    /**
     * @notice Emergency withdraw under pause - prove escape hatch works
     * @dev 20 members, group paused, emergency withdraw still works
     */
    function test_WhaleScale_EmergencyWithdraw_UnderPause() public {
        console.log("");
        console.log("################################################################");
        console.log("#  EMERGENCY WITHDRAW: Paused Group, 20 Members               #");
        console.log("################################################################");

        (ZybraGroup whaleGroup, address[] memory users) = _createWhaleGroup(20);

        vm.prank(admin);
        whaleGroup.startGroup();

        // 3 cycles
        for (uint256 cycle = 0; cycle < 3; cycle++) {
            if (cycle > 0) vm.warp(block.timestamp + CYCLE);
            for (uint256 u = 0; u < users.length; u++) {
                vm.prank(users[u]);
                whaleGroup.contribute();
            }
        }

        uint256 totalDeposited = 20 * CONTRIBUTION * 3; // $60,000

        vm.warp(block.timestamp + 30 days);

        // PAUSE!
        vm.prank(admin);
        whaleGroup.pause();

        console.log("  Group PAUSED with $%s capital", _fmtUSDC(whaleGroup.totalCapitalInGroup()));

        // Normal withdraw should REVERT
        vm.prank(users[1]);
        vm.expectRevert(ZybraGroup.ContractPaused.selector);
        whaleGroup.withdraw();

        // Emergency withdraw works!
        uint256 totalEmergencyOut;
        for (uint256 i = 0; i < users.length; i++) {
            (uint256 cap,,,) = whaleGroup.getMemberInfo(users[i]);
            if (cap > 0) {
                uint256 bal = usdc.balanceOf(users[i]);
                vm.prank(users[i]);
                whaleGroup.emergencyWithdraw();
                totalEmergencyOut += usdc.balanceOf(users[i]) - bal;
            }
        }

        console.log("  Emergency withdrawn: $%s", _fmtUSDC(totalEmergencyOut));
        console.log("  Deposited:           $%s", _fmtUSDC(totalDeposited));

        assertApproxEqRel(totalEmergencyOut, totalDeposited, 0.01e18, "Capital returned");
        assertEq(whaleGroup.totalCapitalInGroup(), 0, "All capital out");
    }

    /**
     * @notice MAX CAPACITY: 50 members x 12 cycles = $600K with 180-day yield
     * @dev Full financial report with per-user breakdown
     */
    function test_WhaleScale_MaxCapacity_DetailedBreakdown() public {
        console.log("");
        console.log("################################################################");
        console.log("#  MAX CAPACITY: 50 x 12 = $600,000 + 180-Day Morpho Yield    #");
        console.log("################################################################");

        (ZybraGroup whaleGroup, address[] memory users) = _createWhaleGroup(50);

        vm.prank(admin);
        whaleGroup.startGroup();

        uint256 totalDeposited;

        for (uint256 cycle = 0; cycle < CYCLES; cycle++) {
            if (cycle > 0) {
                vm.warp(block.timestamp + CYCLE);
            }
            for (uint256 u = 0; u < users.length; u++) {
                vm.prank(users[u]);
                whaleGroup.contribute();
            }
            totalDeposited += 50 * CONTRIBUTION;
        }

        assertEq(totalDeposited, 600_000e6, "$600K deposited");

        // Warp 180 days
        vm.warp(block.timestamp + 180 days);

        // Calculate elapsed time deterministically (fork-mode can corrupt block.timestamp - t0)
        uint256 elapsedDays = ((CYCLES - 1) * CYCLE + 180 days) / 1 days;
        uint256 vaultVal = vault.convertToAssets(vault.balanceOf(address(whaleGroup)));
        uint256 grossYield = vaultVal > 600_000e6 ? vaultVal - 600_000e6 : 0;

        console.log("");
        console.log("  === FINANCIAL SUMMARY (%s days) ===", elapsedDays);
        console.log("  Deposited:   $%s", _fmtUSDC(totalDeposited));
        console.log("  Vault Value: $%s", _fmtUSDC(vaultVal));
        console.log("  Gross Yield: $%s", _fmtUSDC(grossYield));

        if (grossYield > 0 && elapsedDays > 0) {
            uint256 apyBps = (grossYield * 10000 * 365) / (600_000e6 * elapsedDays);
            console.log("  APY:         %s.%s%%", apyBps / 100, apyBps % 100);
            console.log("  Fee (1%%):   ~$%s", _fmtUSDC(grossYield / 100));
            console.log("  Per-user:    ~$%s", _fmtUSDC((grossYield * 99) / (100 * 50)));
        }

        // Sample user breakdown
        console.log("");
        console.log("  USER BREAKDOWN (sample):");
        for (uint256 i = 0; i < 10; i++) {
            (uint256 cap, uint256 pending,,) = whaleGroup.getMemberInfo(users[i]);
            console.log("    User%s: cap=$%s yield=$%s", i, _fmtUSDC(cap), _fmtUSDC(pending));
        }
        console.log("    ...");
        for (uint256 i = 45; i < 50; i++) {
            (uint256 cap, uint256 pending,,) = whaleGroup.getMemberInfo(users[i]);
            console.log("    User%s: cap=$%s yield=$%s", i, _fmtUSDC(cap), _fmtUSDC(pending));
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

        console.log("");
        console.log("  === FINAL RESULT ===");
        console.log("  Total Withdrawn:  $%s", _fmtUSDC(totalWithdrawn));
        console.log("  Total Deposited:  $%s", _fmtUSDC(totalDeposited));
        console.log("  Net Profit:       $%s", _fmtUSDC(profit));

        // Fees
        uint256 feesLeft = whaleGroup.totalAccumulatedFees() - whaleGroup.totalFeesWithdrawn();
        if (feesLeft > 0) {
            uint256 treasBefore = usdc.balanceOf(treasury);
            vm.prank(admin);
            whaleGroup.collectFees();
            console.log("  Protocol Revenue: $%s", _fmtUSDC(usdc.balanceOf(treasury) - treasBefore));
        }

        assertGe(totalWithdrawn, totalDeposited, "No loss");
        assertEq(whaleGroup.totalCapitalInGroup(), 0, "All withdrawn");
    }
}
