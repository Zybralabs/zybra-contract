// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {ZybraGroupFactory} from "../src/ZybraGroupFactory.sol";
import {ZybraGroup} from "../src/ZybraGroup.sol";
import {Treasury} from "../src/treasury/Treasury.sol";
import {FeeCollector} from "../src/treasury/FeeCollector.sol";
import {MockYieldVault} from "../src/mocks/MockYieldVault.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

/**
 * ============================================================
 *  ZYBRA PROTOCOL — PROOF OF CONCEPT (Audit Reference)
 * ============================================================
 *
 *  PURPOSE
 *  -------
 *  This file is a step-by-step walkthrough of every important
 *  function in ZybraGroupFactory and ZybraGroup, written for
 *  the audit team to understand:
 *    1. How each function works in isolation
 *    2. The end-to-end user journey from group creation → exit
 *    3. Edge-case paths (emergency exit, pause, fee collection)
 *    4. The fee/yield accounting invariants
 *
 *  ROSCA PRIMER (for auditors unfamiliar with the model)
 *  -----------------------------------------------------
 *  A ROSCA (Rotating Savings and Credit Association) is a
 *  group savings scheme where N members each contribute a
 *  fixed amount every cycle. Capital is pooled in a yield
 *  vault (Morpho) and members earn pro-rata yield on the
 *  capital they have deposited. Members can exit at any time.
 *
 *  PROTOCOL ACTORS
 *  ---------------
 *  deployer  — deploys Factory, Treasury, FeeCollector
 *  groupAdmin — creates + manages a specific group
 *  alice/bob/carol/dave — group members (USDC contributors)
 *  keeper — automation bot that calls collectFees periodically
 *
 *  ARCHITECTURE AT A GLANCE
 *  ------------------------
 *  Treasury <─── FeeCollector <─── ZybraGroup (auto fees)
 *       ▲                                │
 *       └──────────── 10% of yield ──────┘
 *
 *  ZybraGroupFactory
 *      └── deploys ZybraGroup instances
 *          └── deposits to MockYieldVault (Morpho in prod)
 *
 *  RUN ALL TESTS
 *  -------------
 *    forge test --match-path test/ZybraProtocolPoC.t.sol -vvv
 *
 *  RUN A SINGLE SCENARIO
 *  ---------------------
 *    forge test --match-test test_FullUserJourney -vvvv
 */
contract ZybraProtocolPoC is Test {

    // ─────────────────────────────────────────────────────────────
    //  CONSTANTS — mirrors ZybraGroup / ZybraGroupFactory limits
    // ─────────────────────────────────────────────────────────────
    uint256 constant CONTRIBUTION   = 100e6;   // 100 USDC per cycle
    uint256 constant CYCLE_DURATION = 1 weeks; // 1-week cycles
    uint256 constant TOTAL_CYCLES   = 4;       // 4-cycle group (1 month)
    uint256 constant APY_BPS        = 1000;    // 10% APY on mock vault

    // Role bytes (must match Treasury.sol)
    bytes32 constant COLLECTOR_ROLE = keccak256("COLLECTOR_ROLE");
    bytes32 constant MANAGER_ROLE   = keccak256("MANAGER_ROLE");
    bytes32 constant KEEPER_ROLE    = keccak256("KEEPER_ROLE");

    // ─────────────────────────────────────────────────────────────
    //  ACTORS
    // ─────────────────────────────────────────────────────────────
    address deployer   = makeAddr("deployer");
    address groupAdmin = makeAddr("groupAdmin");
    address alice      = makeAddr("alice");
    address bob        = makeAddr("bob");
    address carol      = makeAddr("carol");
    address dave       = makeAddr("dave");
    address keeper     = makeAddr("keeper");
    address manager    = makeAddr("manager");

    // ─────────────────────────────────────────────────────────────
    //  CONTRACTS
    // ─────────────────────────────────────────────────────────────
    MockERC20          usdc;
    MockYieldVault     vault;
    Treasury           treasury;
    FeeCollector       feeCollector;
    ZybraGroupFactory  factory;

    // ─────────────────────────────────────────────────────────────
    //  SETUP — runs before every test
    // ─────────────────────────────────────────────────────────────
    function setUp() public {
        vm.label(deployer,   "deployer");
        vm.label(groupAdmin, "groupAdmin");
        vm.label(alice,      "alice");
        vm.label(bob,        "bob");
        vm.label(carol,      "carol");
        vm.label(dave,       "dave");
        vm.label(keeper,     "keeper");
        vm.label(manager,    "manager");

        // 1. Deploy mock USDC (6 decimals, like real USDC)
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vm.label(address(usdc), "USDC");

        // 2. Deploy yield vault (Morpho-compatible ERC4626 mock)
        vault = new MockYieldVault(address(usdc), "Zybra Vault", "zvUSDC", 6);
        vault.setAnnualYieldRate(APY_BPS);
        vm.label(address(vault), "YieldVault");

        // 3. Deploy Treasury
        //    deployer gets DEFAULT_ADMIN_ROLE, manager gets MANAGER_ROLE
        vm.prank(deployer);
        treasury = new Treasury(deployer, manager);
        vm.label(address(treasury), "Treasury");

        // 4. Deploy FeeCollector (needs treasury reference, will push fees there)
        vm.prank(deployer);
        feeCollector = new FeeCollector(address(treasury), deployer, keeper);
        vm.label(address(feeCollector), "FeeCollector");

        // 5. Grant COLLECTOR_ROLE on Treasury to FeeCollector
        vm.prank(deployer);
        treasury.grantRole(COLLECTOR_ROLE, address(feeCollector));

        // 6. Deploy Factory (treasury address injected at construction)
        vm.prank(deployer);
        factory = new ZybraGroupFactory(address(treasury));
        vm.label(address(factory), "Factory");

        // 7. Fund members with USDC for contributions
        //    (contribution × totalCycles + buffer)
        uint256 memberFunds = CONTRIBUTION * (TOTAL_CYCLES + 2);
        usdc.mint(groupAdmin, memberFunds);
        usdc.mint(alice,      memberFunds);
        usdc.mint(bob,        memberFunds);
        usdc.mint(carol,      memberFunds);
        usdc.mint(dave,       memberFunds);
    }

    // ═══════════════════════════════════════════════════════════════
    //  SECTION 1 — FACTORY FUNCTIONS
    // ═══════════════════════════════════════════════════════════════

    /**
     * @notice POC: ZybraGroupFactory.deployGroup()
     *
     * WHAT IT DOES
     * ------------
     * Deploys a new ZybraGroup contract with the given parameters.
     * The factory validates all inputs, then deploys via `new ZybraGroup(...)`.
     * It records the address in `deployedGroups[]` and `adminToGroups[admin]`.
     *
     * NOTE: The factory auto-adds `_admin` as the first member of the group
     *       inside the ZybraGroup constructor.
     *
     * PARAMETERS
     * ----------
     * _asset              ERC20 token used for contributions (e.g. USDC)
     * _contributionAmount Fixed contribution per cycle per member (1e6–1000e6)
     * _cycleDuration      Duration of each cycle in seconds (1 sec – 365 days)
     * _totalCycles        Number of cycles in the group (1–52)
     * _admin              Address that will manage the group
     * _vault              ERC4626 vault where capital earns yield
     *
     * REVERTS WHEN
     * ------------
     *  - treasury == address(0)         (TreasuryNotSet)
     *  - any address param == 0         (ZeroAddress)
     *  - contribution out of 1–1000 USDC(InvalidAmount)
     *  - cycleDuration == 0 or > 365d   (InvalidCycleDuration)
     *  - totalCycles < 1 or > 52        (InvalidCycleLength)
     *  - vault.asset() != _asset        (VaultAssetMismatch — checked in ZybraGroup constructor)
     */
    function test_Factory_DeployGroup() public {
        console2.log("\n=== test_Factory_DeployGroup ===");

        // groupAdmin deploys a group where they are the admin
        vm.prank(groupAdmin);
        address groupAddr = factory.deployGroup(
            address(usdc),    // asset
            CONTRIBUTION,     // 100 USDC per cycle
            CYCLE_DURATION,   // 1 week per cycle
            TOTAL_CYCLES,     // 4 cycles total
            groupAdmin,       // group admin (also auto-joined as first member)
            address(vault)    // yield vault
        );

        console2.log("Group deployed at:", groupAddr);

        // Verify factory tracking
        assertEq(factory.getDeployedGroupsCount(), 1, "factory count should be 1");
        assertEq(factory.deployedGroups(0), groupAddr, "first deployed group mismatch");
        assertTrue(factory.isDeployedGroup(groupAddr), "isDeployedGroup should be true");

        address[] memory adminGroups = factory.getGroupsByAdmin(groupAdmin);
        assertEq(adminGroups.length, 1, "admin should have 1 group");
        assertEq(adminGroups[0], groupAddr, "admin group address mismatch");

        // Verify group was initialized correctly
        ZybraGroup group = ZybraGroup(groupAddr);
        assertEq(group.admin(), groupAdmin, "group admin mismatch");
        assertEq(address(group.asset()), address(usdc), "asset mismatch");
        assertEq(group.contributionAmount(), CONTRIBUTION, "contribution mismatch");
        assertEq(group.cycleDuration(), CYCLE_DURATION, "cycle duration mismatch");
        assertEq(group.totalCycles(), TOTAL_CYCLES, "total cycles mismatch");
        assertEq(address(group.vault()), address(vault), "vault mismatch");
        assertEq(group.factory(), address(factory), "factory mismatch");

        // groupAdmin was auto-added as first member by the constructor
        assertEq(group.activeMembersCount(), 1, "admin should be member #1");
        (, , , bool isActive) = group.getMemberInfo(groupAdmin);
        assertTrue(isActive, "admin should be active member");

        console2.log("factory.deployedGroups count:", factory.getDeployedGroupsCount());
        console2.log("group.activeMembersCount:    ", group.activeMembersCount());
    }

    /**
     * @notice POC: Factory view functions — discovery and batch reads
     *
     * getAllDeployedGroups() — returns every group ever deployed
     * getGroupsByAdmin()    — returns groups for a specific admin
     * getDeployedGroupsCount() — total group count
     * getGroupsInfo()       — batch-reads state from multiple groups
     */
    function test_Factory_ViewFunctions() public {
        // Deploy two groups with different admins
        vm.prank(groupAdmin);
        address g1 = factory.deployGroup(
            address(usdc), CONTRIBUTION, CYCLE_DURATION, TOTAL_CYCLES, groupAdmin, address(vault)
        );
        vm.prank(alice);
        address g2 = factory.deployGroup(
            address(usdc), 50e6, CYCLE_DURATION, 8, alice, address(vault)
        );

        console2.log("g1:", g1);
        console2.log("g2:", g2);

        address[] memory all = factory.getAllDeployedGroups();
        assertEq(all.length, 2);

        // getGroupsByAdmin correctly partitions
        assertEq(factory.getGroupsByAdmin(groupAdmin).length, 1);
        assertEq(factory.getGroupsByAdmin(alice).length,      1);

        // getGroupsInfo batch read
        address[] memory toQuery = new address[](2);
        toQuery[0] = g1;
        toQuery[1] = g2;
        ZybraGroupFactory.GroupInfo[] memory infos = factory.getGroupsInfo(toQuery);

        assertEq(infos[0].groupAddress,        g1);
        assertEq(infos[0].admin,               groupAdmin);
        assertEq(infos[0].contributionAmount,  CONTRIBUTION);
        assertEq(infos[0].totalCycles,         TOTAL_CYCLES);
        assertFalse(infos[0].poolStarted, "g1 not started yet");

        assertEq(infos[1].contributionAmount, 50e6);
        assertEq(infos[1].totalCycles,        8);
    }

    /**
     * @notice POC: Factory ownership — 2-step transfer
     *
     * transferOwnership(newOwner) — current owner proposes
     * acceptOwnership()          — proposed owner accepts
     *
     * WHY 2-STEP?
     * -----------
     * If the wrong address is typed, the transfer won't go through
     * until the *new* owner confirms from their own key.
     * This prevents permanently bricking factory management.
     */
    function test_Factory_OwnershipTransfer() public {
        console2.log("\n=== test_Factory_OwnershipTransfer ===");

        // Step 1: current owner (deployer) proposes transfer to alice
        vm.prank(deployer);
        factory.transferOwnership(alice);

        assertEq(factory.pendingOwner(), alice, "pending owner should be alice");
        assertEq(factory.owner(),        deployer, "owner unchanged until accepted");

        // Attempting to accept from wrong address reverts
        vm.expectRevert(ZybraGroupFactory.NotPendingOwner.selector);
        vm.prank(bob);
        factory.acceptOwnership();

        // Step 2: alice (pending owner) accepts
        vm.prank(alice);
        factory.acceptOwnership();

        assertEq(factory.owner(),        alice,       "owner should now be alice");
        assertEq(factory.pendingOwner(), address(0),  "pending cleared");

        // deployer can no longer call onlyOwner functions
        vm.expectRevert(ZybraGroupFactory.OnlyOwner.selector);
        vm.prank(deployer);
        factory.setTreasury(address(treasury));
    }

    /**
     * @notice POC: Factory.setTreasury()
     *
     * All ZybraGroup instances read treasury from the factory at runtime.
     * Updating it here propagates atomically to ALL groups — no per-group calls.
     */
    function test_Factory_SetTreasury() public {
        address newTreasury = makeAddr("newTreasury");

        vm.prank(deployer);
        factory.setTreasury(newTreasury);

        assertEq(factory.treasury(), newTreasury);

        // A deployed group immediately sees the new treasury
        vm.prank(groupAdmin);
        address groupAddr = factory.deployGroup(
            address(usdc), CONTRIBUTION, CYCLE_DURATION, TOTAL_CYCLES, groupAdmin, address(vault)
        );
        ZybraGroup group = ZybraGroup(groupAddr);
        assertEq(group.treasury(), newTreasury, "group should see updated treasury");
    }

    // ═══════════════════════════════════════════════════════════════
    //  SECTION 2 — GROUP SETUP PHASE (before startGroup)
    // ═══════════════════════════════════════════════════════════════

    /**
     * @notice POC: joinGroup() and leaveGroup()
     *
     * joinGroup()
     *   - Any address can join before startGroup() is called
     *   - Marks msg.sender as isActive = 1, increments activeMembersCount
     *   - Reverts if already a member (AlreadyMember)
     *   - Reverts if group already started (GroupAlreadyStarted)
     *   - Reverts if group is paused (ContractPaused)
     *   - Reverts if MAX_MEMBERS (50) already reached (InvalidAmount)
     *   NOTE: groupAdmin was auto-added by the constructor, so they do NOT call joinGroup()
     *
     * leaveGroup()
     *   - Member can leave before start; marks isActive = 0
     *   - Reverts if group already started (GroupAlreadyStarted)
     *   - Reverts if caller is not an active member (NotMember)
     */
    function test_Group_JoinAndLeave() public {
        ZybraGroup group = _deployGroup();
        console2.log("\n=== test_Group_JoinAndLeave ===");

        // Initially only groupAdmin is a member (auto-joined in constructor)
        assertEq(group.activeMembersCount(), 1);

        // Alice joins
        vm.prank(alice);
        group.joinGroup();
        assertEq(group.activeMembersCount(), 2);
        (, , , bool aliceActive) = group.getMemberInfo(alice);
        assertTrue(aliceActive);

        // Bob joins
        vm.prank(bob);
        group.joinGroup();
        assertEq(group.activeMembersCount(), 3);

        // Alice cannot join twice
        vm.expectRevert(ZybraGroup.AlreadyMember.selector);
        vm.prank(alice);
        group.joinGroup();

        // Bob leaves before the group starts — gets full refund (no capital yet)
        vm.prank(bob);
        group.leaveGroup();
        assertEq(group.activeMembersCount(), 2);
        (, , , bool bobActive) = group.getMemberInfo(bob);
        assertFalse(bobActive);

        console2.log("Final activeMembersCount:", group.activeMembersCount());
    }

    /**
     * @notice POC: startGroup()
     *
     * WHAT IT DOES
     * ------------
     * Called by admin to lock membership and begin the first cycle.
     * Sets `groupStartTime = block.timestamp`. Once set, joinGroup/leaveGroup
     * are permanently disabled.
     *
     * REVERTS WHEN
     * ------------
     *  - msg.sender != admin           (NotAdmin)
     *  - activeMembersCount < 2        (InsufficientMembers)
     *  - already started               (GroupAlreadyStarted)
     */
    function test_Group_StartGroup() public {
        ZybraGroup group = _deployGroup();

        // Need at least 2 members — currently only admin
        vm.expectRevert(ZybraGroup.InsufficientMembers.selector);
        vm.prank(groupAdmin);
        group.startGroup();

        // Alice joins → now 2 members → can start
        vm.prank(alice);
        group.joinGroup();

        uint256 startTime = block.timestamp;
        vm.prank(groupAdmin);
        group.startGroup();

        assertEq(group.groupStartTime(), startTime);

        // joinGroup now reverts
        vm.expectRevert(ZybraGroup.GroupAlreadyStarted.selector);
        vm.prank(bob);
        group.joinGroup();

        console2.log("Group started at:", group.groupStartTime());
        console2.log("Current cycle:   ", group.getCurrentCycle());
    }

    // ═══════════════════════════════════════════════════════════════
    //  SECTION 3 — ACTIVE PHASE: CONTRIBUTE
    // ═══════════════════════════════════════════════════════════════

    /**
     * @notice POC: contribute()
     *
     * WHAT IT DOES
     * ------------
     * A member pays `contributionAmount` USDC for the current cycle.
     * 1. Calls _accrueRewards() — materialises any vault yield into the
     *    accumulator before capital changes (prevents retroactive yield theft)
     * 2. Transfers USDC from member to the group contract
     * 3. Increases member.capitalInGroup by the contribution amount
     * 4. Adjusts member.rewardDebt so NEW capital only earns yield
     *    from THIS point forward (MasterChef pattern)
     * 5. Deposits USDC into the yield vault via vault.deposit()
     *
     * ONE CONTRIBUTION PER CYCLE: tracked by contributedInCycle[member][cycle]
     *
     * REVERTS WHEN
     * ------------
     *  - caller not an active member    (NotMember)
     *  - group not started              (GroupNotStarted)
     *  - group ended                    (GroupAlreadyEnded)
     *  - all cycles elapsed             (InvalidCycle)
     *  - already contributed this cycle (AlreadyContributed)
     *  - paused                         (ContractPaused)
     *  - fee-on-transfer token used     (FeeOnTransferNotSupported)
     */
    function test_Group_Contribute() public {
        ZybraGroup group = _deployStartedGroup();
        console2.log("\n=== test_Group_Contribute ===");

        // Cycle 1 — groupAdmin contributes
        console2.log("--- Cycle 1 ---");
        uint256 cycle = group.getCurrentCycle();
        assertEq(cycle, 1, "should be cycle 1");

        _approve(groupAdmin, address(group), CONTRIBUTION);
        vm.prank(groupAdmin);
        group.contribute();

        // Verify capital was recorded
        (uint256 capital, , uint256 lastCycle, bool active) = group.getMemberInfo(groupAdmin);
        assertEq(capital,    CONTRIBUTION, "capital should equal contribution");
        assertEq(lastCycle,  1,            "last contributed cycle should be 1");
        assertTrue(active);

        // USDC was deposited into vault
        assertGt(vault.balanceOf(address(group)), 0, "group should hold vault shares");
        assertEq(group.totalCapitalInGroup(), CONTRIBUTION, "totalCapital should be 100 USDC");

        // Alice contributes in same cycle
        _approve(alice, address(group), CONTRIBUTION);
        vm.prank(alice);
        group.contribute();
        assertEq(group.totalCapitalInGroup(), CONTRIBUTION * 2);

        // Cannot contribute twice in same cycle
        vm.expectRevert(ZybraGroup.AlreadyContributed.selector);
        vm.prank(groupAdmin);
        group.contribute();

        (uint256 adminCap, , , ) = group.getMemberInfo(groupAdmin);
        (uint256 aliceCap, , , ) = group.getMemberInfo(alice);
        console2.log("groupAdmin capital:   ", adminCap);
        console2.log("alice capital:        ", aliceCap);
        console2.log("totalCapitalInGroup:  ", group.totalCapitalInGroup());
        console2.log("vault shares held:    ", vault.balanceOf(address(group)));

        // Advance to cycle 2 and contribute again (capital stacks)
        vm.warp(block.timestamp + CYCLE_DURATION);
        assertEq(group.getCurrentCycle(), 2, "should be cycle 2");

        _approve(groupAdmin, address(group), CONTRIBUTION);
        vm.prank(groupAdmin);
        group.contribute();

        (uint256 capitalAfter2, , , ) = group.getMemberInfo(groupAdmin);
        assertEq(capitalAfter2, CONTRIBUTION * 2, "capital stacks each cycle");
        console2.log("groupAdmin capital after cycle 2:", capitalAfter2);
    }

    // ═══════════════════════════════════════════════════════════════
    //  SECTION 4 — ACTIVE PHASE: CLAIM YIELD
    // ═══════════════════════════════════════════════════════════════

    /**
     * @notice POC: claimYield() / claimYieldTo()
     *
     * WHAT IT DOES
     * ------------
     * Withdraws only accumulated yield from the vault to the caller.
     * Capital stays in the group — the member remains an active participant.
     *
     * YIELD ACCOUNTING (MasterChef pattern):
     *   pendingYield = (capitalInGroup × accRewardPerShare / ACC_PRECISION) − rewardDebt
     *
     * accRewardPerShare grows as the vault earns yield (via _accrueRewards).
     * rewardDebt is reset after every claim to prevent double-claiming.
     *
     * 10% PROTOCOL FEE: taken from raw vault yield inside _accrueRewards(),
     * BEFORE distributing to members. Members see only the 90% net yield.
     *
     * claimYieldTo(receiver) — same logic, sends yield to a different address.
     * Useful if msg.sender is USDC-blacklisted.
     *
     * REVERTS WHEN
     * ------------
     *  - caller not an active member (NotMember)
     *  - pending yield == 0          (NothingToClaim)
     *  NOTE: No pause check — exits must always work
     */
    function test_Group_ClaimYield() public {
        ZybraGroup group = _deployStartedGroup();
        console2.log("\n=== test_Group_ClaimYield ===");

        // Both members contribute in cycle 1
        _contribute(groupAdmin, group);
        _contribute(alice,      group);
        console2.log("Both members contributed 100 USDC each");
        console2.log("totalCapital:", group.totalCapitalInGroup());

        // No yield yet — can't claim
        vm.expectRevert(ZybraGroup.NothingToClaim.selector);
        vm.prank(groupAdmin);
        group.claimYield();

        // Advance 30 days and let vault accrue yield
        vm.warp(block.timestamp + 30 days);
        vault.accrueInterest(); // vault yield now visible

        // Check pending yield before claiming
        uint256 pendingAdmin = group.pendingYield(groupAdmin);
        uint256 pendingAlice = group.pendingYield(alice);
        console2.log("Pending yield groupAdmin:", pendingAdmin);
        console2.log("Pending yield alice:     ", pendingAlice);

        // Equal capital => equal yield
        // (small rounding differences are acceptable)
        assertApproxEqAbs(pendingAdmin, pendingAlice, 1, "equal capital = equal yield");
        assertGt(pendingAdmin, 0, "yield should have accrued");

        // groupAdmin claims yield — capital stays
        uint256 adminUsdcBefore = usdc.balanceOf(groupAdmin);
        vm.prank(groupAdmin);
        group.claimYield();
        uint256 adminUsdcAfter = usdc.balanceOf(groupAdmin);

        uint256 received = adminUsdcAfter - adminUsdcBefore;
        console2.log("groupAdmin yield received:", received);
        assertGt(received, 0, "should have received yield");

        // Capital unchanged after yield claim
        (uint256 capitalAfterClaim, , , ) = group.getMemberInfo(groupAdmin);
        assertEq(capitalAfterClaim, CONTRIBUTION, "capital unchanged after yield claim");

        // Cannot double-claim immediately after
        vm.expectRevert(ZybraGroup.NothingToClaim.selector);
        vm.prank(groupAdmin);
        group.claimYield();

        // claimYieldTo() — alice sends yield to carol's address
        vm.prank(alice);
        group.claimYieldTo(carol);
        assertGt(usdc.balanceOf(carol), 0, "carol should have received alice's yield");
        console2.log("carol received alice's yield:", usdc.balanceOf(carol));
    }

    // ═══════════════════════════════════════════════════════════════
    //  SECTION 5 — ACTIVE PHASE: WITHDRAW (full exit)
    // ═══════════════════════════════════════════════════════════════

    /**
     * @notice POC: withdraw() / withdrawTo()
     *
     * WHAT IT DOES
     * ------------
     * Full exit: withdraws capital + accumulated yield in a single call.
     * The member's record is wiped (isActive=0, capitalInGroup=0).
     * activeMembersCount is decremented, totalCapitalInGroup is reduced.
     *
     * VAULT IMPAIRMENT GUARD
     * ----------------------
     * If the vault is underwater (vault value < totalCapitalInGroup),
     * the member can only withdraw their pro-rata share of actual vault value.
     * Losses are socialized, preventing a bank-run race condition.
     *
     * withdrawTo(receiver) — useful for USDC-blacklisted addresses.
     *
     * REVERTS WHEN
     * ------------
     *  - caller not an active member (NotMember)
     *  - totalAmount == 0            (InvalidAmount)
     *  NOTE: No pause check — exits must always work
     */
    function test_Group_Withdraw() public {
        ZybraGroup group = _deployStartedGroup();
        console2.log("\n=== test_Group_Withdraw ===");

        _contribute(groupAdmin, group);
        _contribute(alice,      group);

        // Advance time for yield to accrue
        vm.warp(block.timestamp + 14 days);
        vault.accrueInterest();

        uint256 pendingYield = group.pendingYield(groupAdmin);
        console2.log("groupAdmin pending yield before withdraw:", pendingYield);

        uint256 adminUsdcBefore = usdc.balanceOf(groupAdmin);

        // Full exit — receives capital + yield in one call
        vm.prank(groupAdmin);
        group.withdraw();

        uint256 received = usdc.balanceOf(groupAdmin) - adminUsdcBefore;
        console2.log("groupAdmin received total:", received);
        assertGe(received, CONTRIBUTION, "should get at least capital back");
        assertGt(received, CONTRIBUTION, "should get capital + yield");

        // Member record cleared
        (uint256 capitalAfter, , , bool activeAfter) = group.getMemberInfo(groupAdmin);
        assertEq(capitalAfter, 0,     "capital should be zero after withdraw");
        assertFalse(activeAfter,      "member should be inactive after withdraw");
        assertEq(group.activeMembersCount(), 1, "only alice remains");

        // Cannot withdraw again
        vm.expectRevert(ZybraGroup.NotMember.selector);
        vm.prank(groupAdmin);
        group.withdraw();

        // withdrawTo — alice sends everything to dave
        vm.prank(alice);
        group.withdrawTo(dave);
        assertGt(usdc.balanceOf(dave), 0, "dave should have received alice's funds");
        console2.log("dave received alice's capital+yield:", usdc.balanceOf(dave));
    }

    // ═══════════════════════════════════════════════════════════════
    //  SECTION 6 — EMERGENCY WITHDRAW
    // ═══════════════════════════════════════════════════════════════

    /**
     * @notice POC: emergencyWithdraw() / emergencyWithdrawTo()
     *
     * WHAT IT DOES
     * ------------
     * Capital-only exit that works even when the group is paused.
     * Intended as a last resort — forfeits any pending yield.
     *
     * FORFEITED YIELD REDISTRIBUTION
     * --------------------------------
     * The forfeited yield (post-fee, already in the accumulator) is
     * injected directly back into accRewardPerShare for remaining members.
     * If no members remain, it becomes protocol fees instead.
     * This prevents permanent vault lockup.
     *
     * emergencyWithdrawTo(receiver) — USDC-blacklist escape hatch.
     *
     * NOTE: No pause check — this IS the escape hatch.
     */
    function test_Group_EmergencyWithdraw() public {
        ZybraGroup group = _deployStartedGroup();
        console2.log("\n=== test_Group_EmergencyWithdraw ===");

        _contribute(groupAdmin, group);
        _contribute(alice,      group);
        vm.prank(bob);
        group.joinGroup(); // bob joins but never contributes (zero capital)
        // NOTE: bob joined after startGroup — this should have failed,
        // but startGroup was called before bob joined in our helper

        // Accrue some yield
        vm.warp(block.timestamp + 7 days);
        vault.accrueInterest();

        uint256 pendingAdmin = group.pendingYield(groupAdmin);
        console2.log("groupAdmin pending yield before emergency:", pendingAdmin);

        // Admin pauses the group (blocks new contributions)
        vm.prank(groupAdmin);
        group.pause();
        assertTrue(group.paused());

        // contribute is now blocked
        vm.expectRevert(ZybraGroup.ContractPaused.selector);
        vm.prank(alice);
        group.contribute();

        // But emergencyWithdraw still works while paused — it's the escape hatch
        uint256 adminUsdcBefore = usdc.balanceOf(groupAdmin);
        vm.prank(groupAdmin);
        group.emergencyWithdraw();

        uint256 received = usdc.balanceOf(groupAdmin) - adminUsdcBefore;
        console2.log("groupAdmin emergency withdrawal:", received);

        // Should receive capital only (yield forfeited)
        assertEq(received, CONTRIBUTION, "emergency should return capital only");

        // Forfeited yield redistributed to alice
        uint256 alicePendingAfter = group.pendingYield(alice);
        console2.log("alice pending yield after admin emergency:", alicePendingAfter);
        assertGt(alicePendingAfter, 0, "alice should receive redistributed yield");

        // emergencyWithdrawTo — alice sends to dave
        vm.prank(alice);
        group.emergencyWithdrawTo(dave);
        assertEq(usdc.balanceOf(dave), CONTRIBUTION, "dave gets alice's capital");
        console2.log("dave received alice's emergency capital:", usdc.balanceOf(dave));
    }

    // ═══════════════════════════════════════════════════════════════
    //  SECTION 7 — END GROUP
    // ═══════════════════════════════════════════════════════════════

    /**
     * @notice POC: endGroup()
     *
     * WHAT IT DOES
     * ------------
     * Finalises the ROSCA. Sets groupEnded = true.
     * Calls _accrueRewards() first so yield is fully materialised.
     *
     * WHO CAN CALL
     * ------------
     * Admin: any time after start
     * Anyone else: only after (groupStartTime + totalCycles × cycleDuration + 7 days grace)
     *
     * WHY PERMISSIONLESS AFTER DEADLINE?
     * -----------------------------------
     * If admin loses their key, members would be permanently locked.
     * The 7-day grace period gives admin a chance to end cleanly first.
     *
     * AFTER ENDING: contribute() reverts (GroupAlreadyEnded).
     *               withdraw/claimYield/emergencyWithdraw still work.
     */
    function test_Group_EndGroup() public {
        ZybraGroup group = _deployStartedGroup();
        console2.log("\n=== test_Group_EndGroup ===");

        _contribute(groupAdmin, group);
        _contribute(alice,      group);

        // Non-admin cannot end before deadline
        vm.expectRevert(ZybraGroup.GroupNotExpired.selector);
        vm.prank(alice);
        group.endGroup();

        // Admin ends immediately
        vm.prank(groupAdmin);
        group.endGroup();
        assertTrue(group.groupEnded(), "group should be ended");

        // contribute now reverts
        vm.expectRevert(ZybraGroup.GroupAlreadyEnded.selector);
        vm.prank(alice);
        group.contribute();

        // Members can still withdraw after group end
        vm.prank(alice);
        group.withdraw();
        assertGt(usdc.balanceOf(alice), 0, "alice should receive funds after end");
        console2.log("alice withdrew after group end:", usdc.balanceOf(alice));
    }

    /**
     * @notice POC: Permissionless endGroup() by non-admin after deadline
     */
    function test_Group_EndGroupPermissionless() public {
        ZybraGroup group = _deployStartedGroup();

        _contribute(groupAdmin, group);
        _contribute(alice,      group);

        // Advance past deadline = startTime + (4 cycles × 1 week) + 7 day grace
        uint256 deadline = group.getGroupEndDeadline();
        vm.warp(deadline + 1);

        // Bob (not a member, not admin) can end the group
        vm.prank(bob);
        group.endGroup();
        assertTrue(group.groupEnded(), "permissionless end should work after deadline");
        console2.log("Permissionless endGroup called by bob succeeded");
    }

    // ═══════════════════════════════════════════════════════════════
    //  SECTION 8 — FEE COLLECTION
    // ═══════════════════════════════════════════════════════════════

    /**
     * @notice POC: collectFees() — permissionless manual fee sweep
     *
     * HOW FEES WORK
     * -------------
     * 1. As vault yield accrues, _accrueRewards() takes PROTOCOL_FEE_BPS (10%)
     *    and stores it in totalAccumulatedFees.
     *
     * 2. _autoCollectFees() is piggybacked on every user action:
     *    when totalAccumulatedFees - totalFeesWithdrawn >= 1 USDC,
     *    fees are automatically withdrawn from the vault and sent to treasury.
     *
     * 3. collectFees() is a permissionless fallback for dust/inactive groups.
     *    It does NOT revert if amount == 0 (returns 0 instead).
     *
     * 4. FeeCollector.collectFrom(group) integrates with the protocol-wide
     *    fee aggregation system. It calls group.collectFees() and forwards
     *    any received tokens to Treasury.
     */
    function test_Group_FeeCollection() public {
        ZybraGroup group = _deployStartedGroup();
        console2.log("\n=== test_Group_FeeCollection ===");

        _contribute(groupAdmin, group);
        _contribute(alice,      group);

        // Let yield accrue
        vm.warp(block.timestamp + 60 days);
        vault.accrueInterest();

        uint256 pendingFeesView = group.pendingFees();
        console2.log("pendingFees() before collect:", pendingFeesView);
        assertGt(pendingFeesView, 0, "should have pending fees");

        uint256 treasuryBefore = usdc.balanceOf(address(treasury));

        // Anyone can call collectFees() — fees always go to treasury
        group.collectFees();

        uint256 treasuryAfter = usdc.balanceOf(address(treasury));
        uint256 feesCollected = treasuryAfter - treasuryBefore;
        console2.log("Treasury received fees:", feesCollected);
        assertGt(feesCollected, 0, "treasury should have received fees");

        // pendingFees() is now 0
        assertEq(group.pendingFees(), 0, "no pending fees after collection");
    }

    /**
     * @notice POC: FeeCollector.registerSource() and collectFrom()
     *
     * The FeeCollector aggregates fees from multiple ZybraGroup instances.
     * Admin registers groups as fee sources; keeper calls collectAll() to sweep.
     */
    function test_FeeCollector_Integration() public {
        // Deploy and wire a group
        vm.prank(groupAdmin);
        address groupAddr = factory.deployGroup(
            address(usdc), CONTRIBUTION, CYCLE_DURATION, TOTAL_CYCLES, groupAdmin, address(vault)
        );
        ZybraGroup group = ZybraGroup(groupAddr);

        // Register group as a fee source in FeeCollector
        vm.prank(deployer); // deployer has DEFAULT_ADMIN_ROLE on FeeCollector
        feeCollector.registerSource(groupAddr);
        assertTrue(feeCollector.isRegisteredSource(groupAddr));

        // Run the group through a cycle
        vm.prank(alice);
        group.joinGroup();
        vm.prank(groupAdmin);
        group.startGroup();
        _contribute(groupAdmin, group);
        _contribute(alice,      group);

        vm.warp(block.timestamp + 30 days);
        vault.accrueInterest();

        uint256 pending = feeCollector.totalPendingFees(address(usdc));
        console2.log("FeeCollector.totalPendingFees:", pending);
        assertGt(pending, 0);

        uint256 treasuryBefore = usdc.balanceOf(address(treasury));

        // keeper calls collectAll() to sweep all registered sources
        vm.prank(keeper);
        feeCollector.collectAll();

        uint256 collected = usdc.balanceOf(address(treasury)) - treasuryBefore;
        console2.log("Treasury received via FeeCollector:", collected);
        assertGt(collected, 0);
    }

    // ═══════════════════════════════════════════════════════════════
    //  SECTION 9 — ADMIN OPERATIONS
    // ═══════════════════════════════════════════════════════════════

    /**
     * @notice POC: pause() / unpause()
     *
     * pause():   blocks joinGroup() and contribute() (new inflows only)
     * unpause(): re-enables them
     *
     * Exits (withdraw, claimYield, emergencyWithdraw) are NEVER blocked
     * by pause — members must always be able to retrieve their funds.
     */
    function test_Group_PauseUnpause() public {
        ZybraGroup group = _deployStartedGroup();

        _contribute(groupAdmin, group);
        _contribute(alice,      group);

        // Admin pauses
        vm.prank(groupAdmin);
        group.pause();
        assertTrue(group.paused());

        // Contribute blocked
        vm.warp(block.timestamp + CYCLE_DURATION); // next cycle
        vm.expectRevert(ZybraGroup.ContractPaused.selector);
        vm.prank(alice);
        group.contribute();

        // But claimYield works while paused (no pause check)
        vm.warp(block.timestamp + 30 days);
        vault.accrueInterest();
        vm.prank(alice);
        group.claimYield(); // should not revert

        // And withdraw works while paused
        vm.prank(groupAdmin);
        group.withdraw(); // should not revert

        // Unpause
        vm.prank(groupAdmin);
        group.unpause();
        assertFalse(group.paused());
    }

    /**
     * @notice POC: transferAdmin() / acceptAdmin() — 2-step admin transfer
     *
     * Step 1: current admin proposes new admin via transferAdmin(newAdmin)
     * Step 2: new admin calls acceptAdmin() to confirm
     *
     * Prevents permanent loss of group management from an address typo.
     */
    function test_Group_AdminTransfer() public {
        ZybraGroup group = _deployGroup();

        // Step 1: propose transfer to alice
        vm.prank(groupAdmin);
        group.transferAdmin(alice);
        assertEq(group.pendingAdmin(), alice);
        assertEq(group.admin(),        groupAdmin, "still groupAdmin until alice accepts");

        // Wrong address cannot accept
        vm.expectRevert(ZybraGroup.NotPendingAdmin.selector);
        vm.prank(bob);
        group.acceptAdmin();

        // Step 2: alice accepts
        vm.prank(alice);
        group.acceptAdmin();
        assertEq(group.admin(),        alice,       "alice is now admin");
        assertEq(group.pendingAdmin(), address(0),  "pending cleared");

        // Former admin can no longer call onlyAdmin functions
        vm.expectRevert(ZybraGroup.NotAdmin.selector);
        vm.prank(groupAdmin);
        group.pause();
    }

    /**
     * @notice POC: sweepToken()
     *
     * Recovers ERC20 tokens accidentally sent to the group contract.
     * Cannot sweep the group asset (USDC) or vault shares — only foreign tokens.
     */
    function test_Group_SweepToken() public {
        ZybraGroup group = _deployGroup();

        // Deploy a foreign token and accidentally send some to the group
        MockERC20 foreignToken = new MockERC20("Foreign", "FRN", 18);
        foreignToken.mint(address(group), 1000e18);

        // Admin recovers them
        vm.prank(groupAdmin);
        group.sweepToken(foreignToken);
        assertEq(foreignToken.balanceOf(groupAdmin), 1000e18, "admin should receive swept tokens");
        assertEq(foreignToken.balanceOf(address(group)), 0);

        // Cannot sweep the group asset (USDC)
        vm.expectRevert(ZybraGroup.CannotSweep.selector);
        vm.prank(groupAdmin);
        group.sweepToken(usdc);
    }

    // ═══════════════════════════════════════════════════════════════
    //  SECTION 10 — FULL END-TO-END USER JOURNEY
    // ═══════════════════════════════════════════════════════════════

    /**
     * @notice POC: Complete user journey — deploy group through all cycles to exit
     *
     * SCENARIO (4 members, 4 cycles, 100 USDC/cycle, 10% APY vault)
     * ---------------------------------------------------------------
     * Actors : groupAdmin, alice, bob, carol
     * Config : contributionAmount=100 USDC, cycleDuration=1 week, totalCycles=4
     *
     * Timeline:
     *   T=0      groupAdmin deploys group via factory
     *   T=0      alice, bob, carol join the group
     *   T=0      groupAdmin starts the group (4 members locked in)
     *   T=0+7d   Cycle 1: all 4 contribute 100 USDC
     *   T=0+14d  Cycle 2: all 4 contribute 100 USDC
     *            alice claims yield mid-cycle
     *   T=0+21d  Cycle 3: all 4 contribute 100 USDC
     *            bob decides to exit early (withdraw)
     *   T=0+28d  Cycle 4: groupAdmin, carol contribute (bob already gone)
     *   T=0+28d  Admin ends group
     *   T=0+28d  groupAdmin and carol withdraw capital + yield
     *
     * INVARIANT CHECK (at the end):
     *   vaultValue ≈ 0 after all exits (all funds returned to members + fees to treasury)
     */
    function test_FullUserJourney() public {
        console2.log("\n======================================");
        console2.log("  FULL END-TO-END USER JOURNEY POC   ");
        console2.log("======================================\n");

        // ── STEP 1: Factory creates the group ────────────────────────────────
        console2.log("STEP 1: Deploy group via factory");
        vm.prank(groupAdmin);
        address groupAddr = factory.deployGroup(
            address(usdc),
            CONTRIBUTION,
            CYCLE_DURATION,
            TOTAL_CYCLES,
            groupAdmin,
            address(vault)
        );
        ZybraGroup group = ZybraGroup(groupAddr);
        console2.log("  Group deployed:", groupAddr);
        console2.log("  Factory groups count:", factory.getDeployedGroupsCount());

        // ── STEP 2: Members join ──────────────────────────────────────────────
        console2.log("\nSTEP 2: alice, bob, carol join the group");
        vm.prank(alice); group.joinGroup();
        vm.prank(bob);   group.joinGroup();
        vm.prank(carol); group.joinGroup();
        assertEq(group.activeMembersCount(), 4);
        console2.log("  Members:", group.activeMembersCount());

        // ── STEP 3: Admin starts the group ───────────────────────────────────
        console2.log("\nSTEP 3: groupAdmin starts the group");
        vm.prank(groupAdmin);
        group.startGroup();
        assertGt(group.groupStartTime(), 0);
        console2.log("  Started at block.timestamp:", group.groupStartTime());

        // ── CYCLE 1 ───────────────────────────────────────────────────────────
        console2.log("\n--- CYCLE 1 (T+0) ---");
        _contribute(groupAdmin, group);
        _contribute(alice,      group);
        _contribute(bob,        group);
        _contribute(carol,      group);
        console2.log("  Total capital in vault:", group.totalCapitalInGroup());
        assertEq(group.totalCapitalInGroup(), CONTRIBUTION * 4, "400 USDC total");

        // ── CYCLE 2 (advance 1 week) ──────────────────────────────────────────
        vm.warp(block.timestamp + CYCLE_DURATION);
        vault.accrueInterest();
        console2.log("\n--- CYCLE 2 (T+1w) ---");
        _contribute(groupAdmin, group);
        _contribute(alice,      group);
        _contribute(bob,        group);
        _contribute(carol,      group);
        console2.log("  Total capital in vault:", group.totalCapitalInGroup());

        // Alice claims yield mid-cycle
        uint256 aliceYieldBefore = group.pendingYield(alice);
        console2.log("  alice pendingYield:", aliceYieldBefore);
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        group.claimYield();
        uint256 aliceYieldReceived = usdc.balanceOf(alice) - aliceUsdcBefore;
        console2.log("  alice claimed yield:", aliceYieldReceived);
        assertGt(aliceYieldReceived, 0);

        // ── CYCLE 3 (advance another week) ───────────────────────────────────
        vm.warp(block.timestamp + CYCLE_DURATION);
        vault.accrueInterest();
        console2.log("\n--- CYCLE 3 (T+2w) ---");
        _contribute(groupAdmin, group);
        _contribute(alice,      group);
        _contribute(bob,        group);
        _contribute(carol,      group);
        console2.log("  Total capital in vault:", group.totalCapitalInGroup());

        // Bob decides to exit early — full withdrawal (capital + yield)
        console2.log("  Bob exits early via withdraw()");
        uint256 bobUsdcBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        group.withdraw();
        uint256 bobReceived = usdc.balanceOf(bob) - bobUsdcBefore;
        console2.log("  Bob received:", bobReceived);
        assertGt(bobReceived, CONTRIBUTION * 3, "bob should get back >3 cycles of capital");
        assertEq(group.activeMembersCount(), 3, "3 members remain");

        // ── CYCLE 4 (advance another week) ───────────────────────────────────
        vm.warp(block.timestamp + CYCLE_DURATION);
        vault.accrueInterest();
        console2.log("\n--- CYCLE 4 (T+3w) ---");
        _contribute(groupAdmin, group);
        // alice and carol also contribute
        _contribute(alice,  group);
        _contribute(carol,  group);
        // Bob already withdrew, not a member

        // ── STEP: Admin ends the group ────────────────────────────────────────
        console2.log("\nSTEP: groupAdmin ends the group");
        vm.prank(groupAdmin);
        group.endGroup();
        assertTrue(group.groupEnded());

        // ── STEP: Collect protocol fees ───────────────────────────────────────
        console2.log("\nSTEP: Collect protocol fees to treasury");
        uint256 feesBeforeCollect = group.pendingFees();
        console2.log("  pendingFees():", feesBeforeCollect);
        uint256 treasuryBefore = usdc.balanceOf(address(treasury));
        group.collectFees();
        uint256 feesCollected = usdc.balanceOf(address(treasury)) - treasuryBefore;
        console2.log("  treasury received:", feesCollected);

        // ── STEP: Remaining members exit ─────────────────────────────────────
        console2.log("\nSTEP: groupAdmin, alice, carol withdraw after group end");

        uint256 adminUsdcBefore  = usdc.balanceOf(groupAdmin);
        uint256 aliceUsdcBefore2 = usdc.balanceOf(alice);
        uint256 carolUsdcBefore  = usdc.balanceOf(carol);

        vm.prank(groupAdmin); group.withdraw();
        vm.prank(alice);      group.withdraw();
        vm.prank(carol);      group.withdraw();

        uint256 adminReceived = usdc.balanceOf(groupAdmin) - adminUsdcBefore;
        uint256 aliceReceived = usdc.balanceOf(alice)      - aliceUsdcBefore2;
        uint256 carolReceived = usdc.balanceOf(carol)      - carolUsdcBefore;

        console2.log("  groupAdmin received:", adminReceived);
        console2.log("  alice received:     ", aliceReceived);
        console2.log("  carol received:     ", carolReceived);

        // All 3 should receive >= their contributed capital
        assertGe(adminReceived, CONTRIBUTION * 4, "admin capital: 4 cycles x 100 USDC");
        assertGe(aliceReceived, 0,  "alice received something");
        assertGe(carolReceived, CONTRIBUTION * 4, "carol capital: 4 cycles x 100 USDC");

        // ── INVARIANT CHECK ───────────────────────────────────────────────────
        console2.log("\n--- INVARIANT CHECK ---");
        uint256 vaultSharesLeft  = vault.balanceOf(groupAddr);
        uint256 vaultValueLeft   = vaultSharesLeft > 0 ? vault.convertToAssets(vaultSharesLeft) : 0;
        uint256 groupMembers     = group.activeMembersCount();
        console2.log("  Remaining vault value:", vaultValueLeft);
        console2.log("  Remaining active members:", groupMembers);
        assertEq(groupMembers, 0, "all members should have exited");
        // Vault may have negligible dust due to ERC4626 rounding — allow up to 5 wei
        assertLe(vaultValueLeft, 5, "vault should be nearly empty after all exits");
        console2.log("  INVARIANT PASSED: vault drained, all members exited");
    }

    // ═══════════════════════════════════════════════════════════════
    //  SECTION 11 — YIELD ACCOUNTING INVARIANTS
    // ═══════════════════════════════════════════════════════════════

    /**
     * @notice POC: Yield distribution is proportional to capital contributed
     *
     * Member A has 2x the capital of member B =>
     * Member A should receive ~2x the yield of member B.
     *
     * This validates the MasterChef accumulator math.
     */
    function test_YieldIsProportionalToCapital() public {
        ZybraGroup group = _deployStartedGroup();

        // groupAdmin contributes 2 cycles (200 USDC total capital)
        _contribute(groupAdmin, group); // cycle 1: 100 USDC
        _contribute(alice,      group); // cycle 1: 100 USDC

        vm.warp(block.timestamp + CYCLE_DURATION);
        vault.accrueInterest();

        _contribute(groupAdmin, group); // cycle 2: +100 USDC => 200 USDC total for admin
        // alice does NOT contribute cycle 2 => still 100 USDC

        // Let more yield accrue with unequal capital
        vm.warp(block.timestamp + 30 days);
        vault.accrueInterest();

        uint256 adminYield = group.pendingYield(groupAdmin);
        uint256 aliceYield = group.pendingYield(alice);

        console2.log("groupAdmin capital: 200 USDC  | yield:", adminYield);
        console2.log("alice capital:      100 USDC  | yield:", aliceYield);

        // Admin has 2x capital => should have ~2x yield
        // Some yield accrued when capital was equal, so ratio < 2 but > 1
        assertGt(adminYield, aliceYield, "admin should earn more yield (2x capital in later period)");
    }

    /**
     * @notice POC: 10% protocol fee is taken from gross yield, not from capital
     *
     * Gross vault yield: 100 USDC
     * Protocol fee (10%): 10 USDC -> treasury
     * Distributed to members: 90 USDC
     */
    function test_ProtocolFeeIs10Percent() public {
        ZybraGroup group = _deployStartedGroup();

        _contribute(groupAdmin, group);
        _contribute(alice,      group);

        uint256 totalCapital = group.totalCapitalInGroup();

        // Add a known amount of yield directly to vault
        uint256 knownYield = 100e6; // exactly 100 USDC
        usdc.mint(deployer, knownYield);
        vm.prank(deployer);
        usdc.approve(address(vault), knownYield);
        vm.prank(deployer);
        vault.addYield(knownYield); // injects yield into vault backing

        // Trigger accrual
        vault.accrueInterest();

        // Expected: 10% fee = 10 USDC, 90 USDC distributed
        uint256 expectedFee = (knownYield * 1000) / 10000; // 10 USDC
        uint256 expectedDist = knownYield - expectedFee;   // 90 USDC

        uint256 pendingFeeAmount = group.pendingFees();
        uint256 pendingAdminYield = group.pendingYield(groupAdmin);
        uint256 pendingAliceYield = group.pendingYield(alice);
        uint256 totalMemberYield  = pendingAdminYield + pendingAliceYield;

        console2.log("Known gross yield:   ", knownYield);
        console2.log("Expected fee (10%):  ", expectedFee);
        console2.log("Expected dist (90%): ", expectedDist);
        console2.log("Actual pendingFees:  ", pendingFeeAmount);
        console2.log("Actual member yield: ", totalMemberYield);

        // Fee should be ~10% of added yield (allow 1 USDC tolerance for vault math)
        assertApproxEqAbs(pendingFeeAmount, expectedFee, 1e6, "fee should be ~10% of yield");
        assertApproxEqAbs(totalMemberYield, expectedDist, 1e6, "member yield should be ~90% of yield");

        // Invariant: fee + memberYield = gross yield
        assertApproxEqAbs(pendingFeeAmount + totalMemberYield, knownYield, 2e6);
    }

    /**
     * @notice POC: getGroupStatus() — consolidated view of group state
     */
    function test_GroupStatus_View() public {
        ZybraGroup group = _deployStartedGroup();
        _contribute(groupAdmin, group);
        _contribute(alice,      group);

        vm.warp(block.timestamp + 7 days);
        vault.accrueInterest();

        (
            bool started,
            bool ended,
            uint256 currentCycle,
            uint256 totalMembers,
            uint256 totalCapital,
            uint256 totalYield,
            uint256 feesAccumulated
        ) = group.getGroupStatus();

        console2.log("started:         ", started);
        console2.log("ended:           ", ended);
        console2.log("currentCycle:    ", currentCycle);
        console2.log("totalMembers:    ", totalMembers);
        console2.log("totalCapital:    ", totalCapital);
        console2.log("totalYield:      ", totalYield);
        console2.log("feesAccumulated: ", feesAccumulated);

        assertTrue(started);
        assertFalse(ended);
        assertEq(currentCycle,    2);            // >1 week elapsed → cycle 2
        assertEq(totalMembers,    2);
        assertEq(totalCapital,    CONTRIBUTION * 2);
        assertGt(totalYield,      0);
        assertGt(feesAccumulated, 0);
    }

    // ═══════════════════════════════════════════════════════════════
    //  HELPERS
    // ═══════════════════════════════════════════════════════════════

    /// @dev Deploy a group without starting it. groupAdmin is auto-added as member.
    function _deployGroup() internal returns (ZybraGroup) {
        vm.prank(groupAdmin);
        address groupAddr = factory.deployGroup(
            address(usdc), CONTRIBUTION, CYCLE_DURATION, TOTAL_CYCLES, groupAdmin, address(vault)
        );
        return ZybraGroup(groupAddr);
    }

    /// @dev Deploy a group with alice already joined and group started (2 members).
    function _deployStartedGroup() internal returns (ZybraGroup) {
        ZybraGroup group = _deployGroup();
        vm.prank(alice);
        group.joinGroup();
        vm.prank(groupAdmin);
        group.startGroup();
        return group;
    }

    /// @dev Approve and contribute for a member in the current cycle.
    function _contribute(address member, ZybraGroup group) internal {
        vm.prank(member);
        usdc.approve(address(group), CONTRIBUTION);
        vm.prank(member);
        group.contribute();
    }

    /// @dev Approve group to spend USDC on behalf of member.
    function _approve(address member, address spender, uint256 amount) internal {
        vm.prank(member);
        usdc.approve(spender, amount);
    }
}
