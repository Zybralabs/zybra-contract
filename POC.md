# Zybra Protocol — Proof of Concept Documentation

> **Audience:** Audit team, security researchers, protocol integrators  
> **Scope:** `ZybraGroupFactory.sol`, `ZybraGroup.sol`, `Treasury.sol`, `FeeCollector.sol`  
> **Test file:** `test/ZybraProtocolPoC.t.sol`

---

## Table of Contents

1. [Protocol Overview](#1-protocol-overview)
2. [Architecture](#2-architecture)
3. [Actors & Roles](#3-actors--roles)
4. [Contract Constants & Limits](#4-contract-constants--limits)
5. [ZybraGroupFactory — Functions](#5-zybragroup-factory--functions)
6. [ZybraGroup — Setup Phase](#6-zybragroup--setup-phase)
7. [ZybraGroup — Active Phase](#7-zybragroup--active-phase)
8. [ZybraGroup — Exit Functions](#8-zybragroup--exit-functions)
9. [ZybraGroup — Admin Functions](#9-zybragroup--admin-functions)
10. [Yield & Fee Accounting](#10-yield--fee-accounting)
11. [Treasury & FeeCollector](#11-treasury--feecollector)
12. [Full User Journey Example](#12-full-user-journey-example)
13. [Invariants](#13-invariants)
14. [Behaviour Reference Table](#14-behaviour-reference-table)

---

## 1. Protocol Overview

Zybra is a **ROSCA** (Rotating Savings and Credit Association) protocol built on EVM chains.

A ROSCA is a group savings scheme:
- A fixed number of members each contribute a fixed amount of tokens every cycle.
- All contributions are deposited into a yield-generating vault (Morpho ERC4626).
- Members earn yield proportional to the capital they have deposited.
- Members can exit at any time, receiving their capital plus accrued yield.
- The protocol takes a **10% flat fee** on all vault yield. These fees flow to a shared `Treasury`.

The **factory** creates groups on demand. Each group is a standalone contract with its own vault allocation, cycle schedule, and member list.

---

## 2. Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│                         PROTOCOL LAYER                           │
│                                                                  │
│   ZybraGroupFactory                                              │
│   ├── treasury (read-only ref)                                   │
│   ├── deployedGroups[]                                           │
│   └── deploys → ZybraGroup instances                            │
│                                                                  │
│   Treasury                  FeeCollector                         │
│   ├── COLLECTOR_ROLE ←──── (registers groups as fee sources)    │
│   ├── MANAGER_ROLE                                               │
│   └── DEFAULT_ADMIN_ROLE                                         │
└──────────────────────────────────────────────────────────────────┘
             ▲ fees (10% of yield)
             │
┌──────────────────────────────────────────────────────────────────┐
│                          GROUP LAYER                             │
│                                                                  │
│   ZybraGroup (one per savings group)                             │
│   ├── asset: USDC (ERC20)                                        │
│   ├── vault: Morpho ERC4626                                      │
│   ├── members[]: up to 50 addresses                              │
│   ├── contributionAmount: fixed per cycle                        │
│   ├── cycleDuration: e.g. 1 week                                 │
│   └── totalCycles: e.g. 4                                        │
└──────────────────────────────────────────────────────────────────┘
             ▲ deposit/withdraw
             │
┌──────────────────────────────────────────────────────────────────┐
│                          VAULT LAYER                             │
│   Morpho ERC4626 Vault (production) / MockYieldVault (tests)    │
│   └── earns yield over time on deposited USDC                   │
└──────────────────────────────────────────────────────────────────┘
```

**Fee flow:**
```
Vault yield generated
    └── _accrueRewards() splits it
            ├── 90% → accRewardPerShare  (members claim via claimYield / withdraw)
            └── 10% → totalAccumulatedFees
                          └── _autoCollectFees() → vault.withdraw → treasury
```

**Treasury read pattern (one-to-all):**  
Groups never store the treasury address. They call `factory.treasury()` at runtime. Updating the factory once propagates to all groups instantly.

---

## 3. Actors & Roles

| Actor | Description |
|---|---|
| **Protocol deployer** | Deploys Treasury, FeeCollector, Factory. Holds `DEFAULT_ADMIN_ROLE`. |
| **Factory owner** | Can call `setTreasury()`, `transferOwnership()`. Initially the deployer. |
| **Group admin** | Creates and manages one group. Can `startGroup`, `endGroup`, `pause`, `unpause`, `transferAdmin`. Auto-joined as first member at construction. |
| **Member** | Any address that calls `joinGroup()` before start. Contributes USDC each cycle, earns yield, can exit at any time. |
| **Keeper** | Automation bot with `KEEPER_ROLE` on FeeCollector. Calls `collectAll()` to batch-sweep fees from all groups. |
| **Manager** | Holds `MANAGER_ROLE` on Treasury. Can call `withdraw()` and `withdrawAll()` on treasury. |

---

## 4. Contract Constants & Limits

### ZybraGroupFactory

| Constant | Value | Meaning |
|---|---|---|
| `MIN_CONTRIBUTION` | `1e6` | 1 USDC minimum contribution per cycle |
| `MAX_CONTRIBUTION` | `1000e6` | 1,000 USDC maximum contribution per cycle |
| `MIN_CYCLE_LENGTH` | `1` | At least 1 cycle |
| `MAX_CYCLE_LENGTH` | `52` | At most 52 cycles (1 year of weekly cycles) |
| `MAX_CYCLE_DURATION` | `365 days` | Each cycle cannot exceed 1 year |

### ZybraGroup

| Constant | Value | Meaning |
|---|---|---|
| `MAX_MEMBERS` | `50` | Hard cap on group size |
| `MIN_MEMBERS` | `2` | Need at least 2 to start |
| `PROTOCOL_FEE_BPS` | `1000` | 10% of yield taken as protocol fee |
| `ACC_PRECISION` | `1e12` | MasterChef accumulator scaling factor |
| `END_GROUP_GRACE_PERIOD` | `7 days` | After all cycles end, admin has 7 days before anyone can force-end |
| `MIN_FEE_AUTO_COLLECT` | `1e6` | Auto-forward fees when >= 1 USDC pending |
| `MAX_YIELD_PER_ACCRUAL_BPS` | `1000` | Max 10% of capital can be accrued per `_accrueRewards()` call (flash-loan protection) |

---

## 5. ZybraGroupFactory — Functions

### `deployGroup(asset, contributionAmount, cycleDuration, totalCycles, admin, vault)`

**What it does:**  
Deploys a new `ZybraGroup` contract. Validates all parameters, calls `new ZybraGroup(...)`, tracks the address in internal mappings, and emits `GroupDeployed`.

The factory passes `_admin` as both the group admin and the first member. The `ZybraGroup` constructor auto-calls `_addMember(_admin)`, so the admin does not need to call `joinGroup()` themselves.

**Parameters:**

| Parameter | Type | Valid Range |
|---|---|---|
| `asset` | `address` | Non-zero, must match vault's underlying asset |
| `contributionAmount` | `uint256` | `1e6` to `1000e6` (1–1,000 USDC) |
| `cycleDuration` | `uint256` | `1` second to `365 days` |
| `totalCycles` | `uint256` | `1` to `52` |
| `admin` | `address` | Non-zero |
| `vault` | `address` | Non-zero, `vault.asset()` must equal `asset` |

**Normal behaviour:**
```solidity
// groupAdmin deploys a 4-week group with 100 USDC/week contributions
address groupAddr = factory.deployGroup(
    address(usdc),   // USDC token
    100e6,           // 100 USDC per cycle
    7 days,          // 1 cycle = 1 week
    4,               // 4 cycles total
    groupAdmin,      // group admin (also first member)
    address(vault)   // Morpho vault
);

// groupAdmin is automatically a member
ZybraGroup group = ZybraGroup(groupAddr);
group.activeMembersCount(); // => 1  (admin pre-joined)
group.admin();              // => groupAdmin
factory.isDeployedGroup(groupAddr); // => true
```

**Should NOT happen:**
```solidity
// Contribution below minimum (1 USDC)
factory.deployGroup(usdc, 0.5e6, 7 days, 4, admin, vault);
// reverts: InvalidAmount

// Vault asset mismatch (vault holds DAI, group uses USDC)
factory.deployGroup(usdc, 100e6, 7 days, 4, admin, daiVault);
// reverts: VaultAssetMismatch (inside ZybraGroup constructor)

// More than 52 cycles
factory.deployGroup(usdc, 100e6, 7 days, 53, admin, vault);
// reverts: InvalidCycleLength

// Treasury not set (address(0))
// This can only happen if factory was constructed incorrectly;
// constructor already reverts on address(0) treasury.
```

---

### `getAllDeployedGroups()` / `getGroupsByAdmin(admin)` / `getDeployedGroupsCount()`

View functions for protocol-wide group discovery.

```solidity
// All groups ever deployed
address[] memory all = factory.getAllDeployedGroups();

// Groups for a specific admin
address[] memory myGroups = factory.getGroupsByAdmin(groupAdmin);

// Total count
uint256 count = factory.getDeployedGroupsCount();
```

---

### `getGroupsInfo(address[] groups)`

Batch-reads on-chain state from multiple groups in one call. Returns `GroupInfo[]` structs.

```solidity
address[] memory toQuery = new address[](2);
toQuery[0] = groupA;
toQuery[1] = groupB;

ZybraGroupFactory.GroupInfo[] memory infos = factory.getGroupsInfo(toQuery);
// infos[0].contributionAmount, infos[0].currentCycle, infos[0].memberCount, etc.
```

**Note:** If an address in the array is not a factory-deployed group, `isDeployedGroup` returns false and the struct at that index is left zero-valued. It does **not** revert.

---

### `setTreasury(newTreasury)` — owner only

Updates the protocol treasury address. Because all groups read treasury from the factory at runtime, this change takes effect immediately for all existing and future groups.

```solidity
vm.prank(factoryOwner);
factory.setTreasury(newMultisig);
// ALL deployed groups now route fees to newMultisig
```

**Should NOT happen:**
```solidity
vm.prank(randomUser);
factory.setTreasury(newAddr);
// reverts: OnlyOwner
```

---

### `transferOwnership(newOwner)` / `acceptOwnership()` — 2-step

Prevents bricking factory management from a typo.

```solidity
// Step 1 — current owner proposes
vm.prank(currentOwner);
factory.transferOwnership(multisig);
factory.pendingOwner(); // => multisig

// Step 2 — new owner accepts from their own key
vm.prank(multisig);
factory.acceptOwnership();
factory.owner(); // => multisig
```

**Should NOT happen:**
```solidity
// Accepting from a different address than pendingOwner
vm.prank(attacker);
factory.acceptOwnership();
// reverts: NotPendingOwner
```

---

## 6. ZybraGroup — Setup Phase

The setup phase is the window between deployment and the admin calling `startGroup()`. During this time, members can join or leave freely. No capital moves yet.

---

### `joinGroup()`

**What it does:**  
Marks `msg.sender` as an active member (`isActive = 1`). Adds them to `membersList[]` and increments `activeMembersCount`.

**Pre-conditions:**
- Group has not started (`groupStartTime == 0`)
- Caller is not already a member
- Group is not paused
- Member count below `MAX_MEMBERS` (50)

**Normal behaviour:**
```solidity
vm.prank(alice);
group.joinGroup();
// alice is now a member, activeMembersCount += 1
// alice.capitalInGroup = 0 (no capital yet, just registered)
```

**Should NOT happen:**
```solidity
// Joining after group has started
vm.prank(bob);
group.joinGroup(); // reverts: GroupAlreadyStarted

// Joining twice
vm.prank(alice);
group.joinGroup(); // reverts: AlreadyMember (already joined above)

// Joining a paused group
group.pause(); // admin pauses
vm.prank(carol);
group.joinGroup(); // reverts: ContractPaused
```

> **Note for auditors:** A member who joined but never contributed will have `capitalInGroup = 0`. They can still call `claimYield()` and `withdraw()`, but `_pendingReward()` returns 0 for zero capital. They earn nothing.

---

### `leaveGroup()`

**What it does:**  
Marks `msg.sender` as inactive (`isActive = 0`) and decrements `activeMembersCount`. Only available before the group starts. No capital to refund because no contributions have been made yet.

**Normal behaviour:**
```solidity
vm.prank(bob);
group.leaveGroup();
// bob.isActive = 0, activeMembersCount -= 1
```

**Should NOT happen:**
```solidity
// Leaving after group started
vm.prank(bob);
group.leaveGroup(); // reverts: GroupAlreadyStarted

// Non-member trying to leave
vm.prank(randomUser);
group.leaveGroup(); // reverts: NotMember
```

---

### `startGroup()` — admin only

**What it does:**  
Locks membership permanently and sets `groupStartTime = block.timestamp`. After this call, `joinGroup()` and `leaveGroup()` both revert for all addresses. Cycle 1 begins immediately.

**Pre-conditions:**
- Caller is `admin`
- `activeMembersCount >= 2` (cannot start a ROSCA with only one person)
- Not already started

**Normal behaviour:**
```solidity
// At least 2 members required
vm.prank(groupAdmin);
group.startGroup();
// groupStartTime = block.timestamp
// getCurrentCycle() => 1
```

**Should NOT happen:**
```solidity
// Starting with only 1 member (just the admin)
vm.prank(groupAdmin);
group.startGroup(); // reverts: InsufficientMembers

// Non-admin trying to start
vm.prank(alice);
group.startGroup(); // reverts: NotAdmin

// Starting twice
vm.prank(groupAdmin);
group.startGroup(); // reverts: GroupAlreadyStarted
```

---

## 7. ZybraGroup — Active Phase

After `startGroup()`, cycles run on a fixed schedule (`groupStartTime + n × cycleDuration`). Members contribute each cycle, capital is deposited to the vault, and yield accrues over time.

---

### `getCurrentCycle()`

View function. Returns the current cycle number (1-indexed). Returns `0` before the group starts. Caps at `totalCycles` — it never returns a value higher than the configured limit.

```solidity
// At T=0 (start):        getCurrentCycle() => 1
// At T=1w (1 week):      getCurrentCycle() => 2
// At T=4w+ (after end):  getCurrentCycle() => 4  (capped)
```

---

### `contribute()`

**What it does:**  
Transfers exactly `contributionAmount` USDC from the member, deposits it into the yield vault, and records the contribution for the current cycle.

**Yield accounting update (critical):** Before changing any capital, `_accrueRewards()` is called. This materialises all pending vault yield into `accRewardPerShare`. The member's `rewardDebt` is then adjusted so their newly added capital only earns yield from *this point forward* — not retroactively.

**One contribution per cycle per member.** Tracked by `contributedInCycle[member][cycle]`.

**Capital stacks across cycles:** If Alice contributes 100 USDC in cycle 1 and 100 USDC in cycle 2, her `capitalInGroup` becomes 200 USDC. She earns yield on 200 USDC from cycle 2 onward.

**Normal behaviour:**
```solidity
// Approve first
usdc.approve(address(group), 100e6);

vm.prank(alice);
group.contribute();
// alice.capitalInGroup += 100e6
// totalCapitalInGroup  += 100e6
// vault.deposit(100e6) called — vault shares minted to group
// contributedInCycle[alice][1] = true
```

**Should NOT happen:**
```solidity
// Contributing in wrong cycle (e.g. cycle 0, or past totalCycles)
// block.timestamp >= groupStartTime + totalCycles * cycleDuration
vm.prank(alice);
group.contribute(); // reverts: InvalidCycle

// Contributing twice in same cycle
vm.prank(alice);
group.contribute(); // reverts: AlreadyContributed

// Non-member contributing
vm.prank(randomUser);
group.contribute(); // reverts: NotMember

// Contributing while paused
group.pause();
vm.prank(alice);
group.contribute(); // reverts: ContractPaused

// Fee-on-transfer token slipping through
// (tokens received < tokens transferred)
// The contract checks: received == contributionAmount
// reverts: FeeOnTransferNotSupported
```

---

### `pendingYield(address user)` — view

Returns the live pending yield for a user without modifying state. Simulates `_accrueRewards()` internally to reflect the latest vault value.

```solidity
uint256 yield = group.pendingYield(alice);
// Returns: (alice.capitalInGroup × live_accRewardPerShare / ACC_PRECISION) - alice.rewardDebt
```

**Important:** The returned value is already net of the 10% protocol fee. Members see only their 90% share.

---

### `getGroupStatus()` — view

Returns a snapshot of the group's current state.

```solidity
(
    bool started,
    bool ended,
    uint256 currentCycle,
    uint256 totalMembers,
    uint256 totalCapital,
    uint256 totalYield,      // gross vault yield above principal
    uint256 feesAccumulated  // protocol fees pending withdrawal
) = group.getGroupStatus();
```

---

### `getMemberInfo(address member)` — view

```solidity
(
    uint256 capitalInGroup,
    uint256 pendingYieldAmount,  // live, net of fees
    uint256 lastContributedCycle,
    bool    isActive
) = group.getMemberInfo(alice);
```

---

## 8. ZybraGroup — Exit Functions

All exit functions (`claimYield`, `withdraw`, `emergencyWithdraw`) work even when the group is **paused**. This is intentional — the pause flag only blocks new inflows (contributions, new joins). Members must always be able to retrieve their funds.

---

### `claimYield()` / `claimYieldTo(receiver)`

**What it does:**  
Withdraws accumulated yield from the vault to the caller. Capital stays in the group — the member remains active and continues earning.

**Steps internally:**
1. `_accrueRewards()` — sync latest vault yield into accumulator
2. Compute `pending = (capitalInGroup × accRewardPerShare / ACC_PRECISION) - rewardDebt`
3. Reset `rewardDebt` to prevent double-claiming
4. Increment `totalDistributedYield` (used for yield accounting reconstruction)
5. `vault.withdraw(pending, receiver)` — pull USDC from vault to recipient

`claimYieldTo(receiver)` sends yield to an alternative address. Use case: the member's wallet is USDC-blacklisted.

**Normal behaviour:**
```solidity
// After yield has accrued
vm.prank(alice);
group.claimYield();
// alice receives USDC yield
// alice.capitalInGroup unchanged
// alice.rewardDebt updated to current accRewardPerShare × capital
```

**Should NOT happen:**
```solidity
// Claiming before any yield exists
vm.prank(alice);
group.claimYield(); // reverts: NothingToClaim

// Claiming twice without new yield accruing
vm.prank(alice);
group.claimYield(); // first call succeeds
vm.prank(alice);
group.claimYield(); // reverts: NothingToClaim  (rewardDebt was reset)

// Non-member claiming
vm.prank(randomUser);
group.claimYield(); // reverts: NotMember

// claimYieldTo with zero address
vm.prank(alice);
group.claimYieldTo(address(0)); // reverts: ZeroAddress
```

---

### `withdraw()` / `withdrawTo(receiver)`

**What it does:**  
Full exit: the member receives their entire `capitalInGroup` plus all pending yield in a single transaction. Their member record is wiped (`isActive = 0`, `capitalInGroup = 0`). `activeMembersCount` is decremented.

**Vault impairment guard:** If the vault is underwater (vault's total value < `totalCapitalInGroup`), each exiting member can only claim their *proportional share* of the actual vault value. This socialises losses fairly and prevents a first-exit-wins bank run.

```
// Normal (healthy vault):
withdrawal = capitalInGroup + pendingYield

// Impaired vault (vault value < totalCapital):
withdrawal = (vaultValue × capitalInGroup) / totalCapitalInGroup
           // no yield portion — losses socialised
```

**Normal behaviour:**
```solidity
// alice has 200 USDC capital + 10 USDC yield
vm.prank(alice);
group.withdraw();
// alice receives ~210 USDC
// alice.isActive = 0, alice.capitalInGroup = 0
// activeMembersCount -= 1
// totalCapitalInGroup -= 200e6
```

**Should NOT happen:**
```solidity
// Withdrawing with zero capital (joined but never contributed)
vm.prank(newMember); // isActive=1 but capitalInGroup=0
group.withdraw(); // reverts: InvalidAmount

// Withdrawing twice (record already cleared)
vm.prank(alice);
group.withdraw();
vm.prank(alice);
group.withdraw(); // reverts: NotMember  (isActive cleared)

// withdrawTo with zero address
vm.prank(alice);
group.withdrawTo(address(0)); // reverts: ZeroAddress
```

---

### `emergencyWithdraw()` / `emergencyWithdrawTo(receiver)`

**What it does:**  
Capital-only exit. Forfeits all pending yield. Works regardless of pause state. Intended as a last resort when normal withdrawal is not feasible.

**Forfeited yield redistribution:** The pending yield the exiting member forfeits is injected directly back into `accRewardPerShare` for remaining members. If no members remain, it becomes protocol fees. This prevents yield from being permanently locked in the vault.

**Normal behaviour:**
```solidity
// alice has 100 USDC capital + 5 USDC pending yield
// Group is paused
vm.prank(alice);
group.emergencyWithdraw();
// alice receives exactly 100 USDC (capital only)
// alice's 5 USDC forfeited yield redistributed to remaining members
// activeMembersCount -= 1
```

**Should NOT happen:**
```solidity
// Emergency withdrawing with no capital deposited
// (joined group but never contributed, capitalInGroup = 0)
vm.prank(newMember);
group.emergencyWithdraw(); // reverts: InvalidAmount

// Non-member calling
vm.prank(randomUser);
group.emergencyWithdraw(); // reverts: NotMember
```

---

### `endGroup()`

**What it does:**  
Finalises the ROSCA. Sets `groupEnded = true`. Calls `_accrueRewards()` first to snapshot the final yield state. After this, `contribute()` reverts for everyone. `withdraw()`, `claimYield()`, and `emergencyWithdraw()` still work normally.

**Who can call it:**
- **Admin:** any time after `startGroup()`
- **Anyone:** only after `getGroupEndDeadline()` = `groupStartTime + (totalCycles × cycleDuration) + 7 days`

The 7-day grace period allows the admin to end cleanly. After expiry, any address can force-end the group — this prevents admin key loss from permanently locking member funds.

**Normal behaviour:**
```solidity
// Admin ends the group after all cycles are complete
vm.prank(groupAdmin);
group.endGroup();
// group.groupEnded() => true

// OR: after deadline, anyone can end
vm.warp(group.getGroupEndDeadline() + 1);
vm.prank(randomUser);
group.endGroup(); // succeeds
```

**Should NOT happen:**
```solidity
// Non-admin ending before deadline
vm.prank(alice);
group.endGroup(); // reverts: GroupNotExpired

// Ending before the group has started
vm.prank(groupAdmin);
group.endGroup(); // reverts: GroupNotStarted

// Ending twice
vm.prank(groupAdmin);
group.endGroup();
vm.prank(groupAdmin);
group.endGroup(); // reverts: GroupAlreadyEnded
```

---

## 9. ZybraGroup — Admin Functions

---

### `pause()` / `unpause()` — admin only

`pause()` blocks `joinGroup()` and `contribute()`. Exit functions (`claimYield`, `withdraw`, `emergencyWithdraw`) are **never** blocked.

```solidity
vm.prank(groupAdmin);
group.pause();
// group.paused() => true
// contribute() now reverts: ContractPaused
// claimYield() / withdraw() / emergencyWithdraw() still work

vm.prank(groupAdmin);
group.unpause();
// group.paused() => false — normal operations resume
```

**Should NOT happen:**
```solidity
// Non-admin pausing
vm.prank(alice);
group.pause(); // reverts: NotAdmin
```

---

### `transferAdmin(newAdmin)` / `acceptAdmin()` — 2-step

Prevents group management from being bricked by a typo.

```solidity
// Step 1: current admin proposes
vm.prank(groupAdmin);
group.transferAdmin(newAdmin);
// group.pendingAdmin() => newAdmin
// group.admin() still => groupAdmin

// Step 2: new admin confirms from their own key
vm.prank(newAdmin);
group.acceptAdmin();
// group.admin() => newAdmin
// group.pendingAdmin() => address(0)
```

**Should NOT happen:**
```solidity
// Accepting from wrong address
vm.prank(attacker);
group.acceptAdmin(); // reverts: NotPendingAdmin

// Proposing zero address
vm.prank(groupAdmin);
group.transferAdmin(address(0)); // reverts: ZeroAddress
```

---

### `collectFees()` — permissionless

Manual fee sweep. Permissionless — anyone can call. Fees always flow to `treasury()`. Returns `0` if no fees are pending (does not revert).

The primary fee mechanism is **automatic**: `_autoCollectFees()` is piggybacked on every user action (`contribute`, `claimYield`, `withdraw`, `emergencyWithdraw`). When accumulated fees reach the `MIN_FEE_AUTO_COLLECT` threshold (1 USDC), they are automatically forwarded to the treasury. `collectFees()` is a fallback for:
- Dust amounts below the auto-collect threshold
- Inactive groups where user actions have stopped

```solidity
// Anyone can call
uint256 collected = group.collectFees();
// Fees sent directly to factory.treasury()
```

**Should NOT happen:**
```solidity
// collectFees should NEVER pull from member capital
// The contract checks: withdrawableForFees = max(vaultValue - totalCapital, 0)
// So if vault is impaired, fee collection returns 0, not member funds
```

---

### `sweepToken(token)` — admin only

Recovers accidentally sent ERC20 tokens. Cannot sweep the group's own `asset` (USDC) or `vault` shares.

```solidity
vm.prank(groupAdmin);
group.sweepToken(IERC20(wethAddress));
// WETH balance sent to admin

// Protected assets cannot be swept
vm.prank(groupAdmin);
group.sweepToken(IERC20(usdc)); // reverts: CannotSweep
group.sweepToken(IERC20(vault)); // reverts: CannotSweep
```

---

## 10. Yield & Fee Accounting

### The Accumulator Pattern (MasterChef)

Zybra uses the same accounting model as Sushiswap MasterChef / Aave rewards:

```
accRewardPerShare += (newDistributableYield × ACC_PRECISION) / totalCapitalInGroup

pendingReward(user) = (user.capitalInGroup × accRewardPerShare / ACC_PRECISION)
                    - user.rewardDebt
```

`rewardDebt` is the "watermark" — it represents how much of `accRewardPerShare` has already been credited to the user. When a user's capital increases (via `contribute()`), `rewardDebt` increases proportionally so their new capital only earns yield from that moment.

### Yield Split

Every time `_accrueRewards()` runs:

```
newYield = totalVaultValue - totalCapitalInGroup - lastMaterializedYield_adjustment
fee      = newYield × 10%     → totalAccumulatedFees
distributable = newYield × 90% → accRewardPerShare increases
```

### Flash-Loan Protection (MAX_YIELD_PER_ACCRUAL_BPS)

If an attacker inflates the vault's `convertToAssets()` by donating tokens directly to the vault contract, `newYield` would be artificially large. The cap limits a single accrual to `10% of totalCapitalInGroup`. Any excess is deferred to the next call once the price normalises.

### Auto-Fee Collection

```
_autoCollectFees() is called at the end of every _accrueRewards()

If (totalAccumulatedFees - totalFeesWithdrawn) >= 1 USDC:
    withdraw fees from vault → send to treasury
    (fees only withdrawn from yield surplus, never from member capital)
```

Uses `try/catch` — fee failure **never blocks** the user's transaction.

---

## 11. Treasury & FeeCollector

### Treasury

Three-role access control:

| Role | Capability |
|---|---|
| `DEFAULT_ADMIN_ROLE` | Grant/revoke roles, `emergencyWithdraw()` |
| `COLLECTOR_ROLE` | `deposit()` — only FeeCollector should have this |
| `MANAGER_ROLE` | `withdraw()`, `withdrawAll()` — operations team |

The Treasury holds no business logic. It is a pure custody contract.

### FeeCollector

Aggregates fees from multiple `ZybraGroup` instances and forwards them to Treasury.

```
Admin registers group → feeCollector.registerSource(groupAddr)
Keeper calls         → feeCollector.collectAll()
  └── for each source:
        group.collectFees() called
        if tokens arrive at FeeCollector: forward to Treasury
        if group pushed directly to Treasury: record accounting only
```

The `_collectFrom()` logic handles both pull-based and push-based fee flows.

---

## 12. Full User Journey Example

**Scenario:** 4 members, 4 weekly cycles, 100 USDC/week contribution, 10% APY vault.

```
ACTORS:
  groupAdmin, alice, bob, carol
  Each starts with 600 USDC (enough for 4 cycles + buffer)

WEEK 0 — Group Creation & Start
────────────────────────────────
1. groupAdmin deploys group via factory.deployGroup(
       asset=USDC, amount=100 USDC, duration=1 week, cycles=4, admin=groupAdmin, vault=vault
   )
   → group deployed; groupAdmin auto-joined as member #1

2. alice, bob, carol each call group.joinGroup()
   → activeMembersCount = 4

3. groupAdmin calls group.startGroup()
   → groupStartTime = now; cycle 1 begins

WEEK 0 — Cycle 1 Contributions
────────────────────────────────
4. All 4 members call group.contribute()
   → each pays 100 USDC; total vault deposit = 400 USDC
   → each member.capitalInGroup = 100 USDC

WEEK 1 — Cycle 2 Contributions (after 1 week)
───────────────────────────────────────────────
5. vm.warp(+1 week); vault accrues ~0.77 USDC yield on 400 USDC
   (400 USDC × 10% APY × 7/365 ≈ 0.77 USDC gross → 0.69 USDC net to members)

6. All 4 contribute again:
   → each member.capitalInGroup = 200 USDC; total vault = 800 USDC

7. alice calls group.claimYield()
   → alice receives ~0.17 USDC (her 25% share of 0.69 USDC net yield)
   → alice.capitalInGroup unchanged = 200 USDC

WEEK 2 — Cycle 3 + Bob's Early Exit
──────────────────────────────────────
8. vm.warp(+1 week); vault accrues more yield
9. All 4 contribute (totalCapital = 1,200 USDC)
10. Bob calls group.withdraw()
    → bob receives ~300 USDC capital + accumulated yield
    → activeMembersCount = 3; totalCapitalInGroup -= 300 USDC

WEEK 3 — Cycle 4 (Final)
──────────────────────────
11. vm.warp(+1 week)
12. groupAdmin, alice, carol contribute (bob already gone)

AFTER FINAL CYCLE
──────────────────
13. groupAdmin calls group.endGroup()
    → groupEnded = true; contribute() now reverts

14. group.collectFees() called (or auto-collected already)
    → treasury receives ~10% of all yield generated

15. groupAdmin, alice, carol each call group.withdraw()
    → each receives their capital (200–400 USDC) + net yield

RESULT:
  vault balance ≈ 0 (all funds returned; dust from ERC4626 rounding only)
  treasury holds protocol fees from all yield
```

---

## 13. Invariants

These conditions must hold at all times. A violation is a critical bug.

| # | Invariant |
|---|---|
| I-1 | `vault.convertToAssets(vault.balanceOf(group))` >= `totalCapitalInGroup` under normal vault conditions |
| I-2 | `totalAccumulatedFees` >= `totalFeesWithdrawn` (fees cannot be over-collected) |
| I-3 | `totalDistributedYield` + pending yields for all members + `totalAccumulatedFees` = `lastMaterializedYield` (yield is fully accounted) |
| I-4 | After all members exit, `vault.balanceOf(group)` ≈ 0 (only rounding dust allowed) |
| I-5 | `collectFees()` never withdraws from `totalCapitalInGroup` (fee cap: `withdrawableForFees = max(vaultValue - totalCapital, 0)`) |
| I-6 | `pendingYield(user) >= 0` for all active members — no negative yields |
| I-7 | A member's `rewardDebt` accurately reflects their cumulative credited yield (no double-claim possible) |
| I-8 | `activeMembersCount` equals the number of addresses with `isActive == 1` |

---

## 14. Behaviour Reference Table

A quick at-a-glance reference for the audit team.

### ZybraGroupFactory

| Function | Who can call | When it reverts | Notes |
|---|---|---|---|
| `deployGroup()` | Anyone | Invalid params, zero addresses, vault mismatch | Admin auto-joined in constructor |
| `getAllDeployedGroups()` | Anyone | Never | Returns empty array if no groups |
| `getGroupsByAdmin()` | Anyone | Never | Returns empty array if admin has no groups |
| `getGroupsInfo()` | Anyone | Never | Unrecognised addresses return zero-value struct |
| `setTreasury()` | Owner only | Zero address | Propagates to all groups instantly |
| `transferOwnership()` | Owner only | Zero address | Sets pendingOwner; 2-step |
| `acceptOwnership()` | pendingOwner only | Wrong caller | Finalises ownership transfer |

### ZybraGroup — Setup Phase

| Function | Who can call | When it reverts |
|---|---|---|
| `joinGroup()` | Anyone | Paused, already started, already member, max members |
| `leaveGroup()` | Active members | Already started, not a member |
| `startGroup()` | Admin only | Already started, < 2 members |

### ZybraGroup — Active Phase

| Function | Who can call | When it reverts | Pause blocks it? |
|---|---|---|---|
| `contribute()` | Active members | Not started, ended, already contributed, invalid cycle, paused, FOT token | YES |
| `claimYield()` | Active members | Nothing to claim, not a member | NO |
| `claimYieldTo()` | Active members | Zero receiver, nothing to claim, not a member | NO |
| `withdraw()` | Active members | Zero balance, not a member | NO |
| `withdrawTo()` | Active members | Zero receiver, zero balance, not a member | NO |
| `emergencyWithdraw()` | Active members | Zero capital, not a member | NO (escape hatch) |
| `emergencyWithdrawTo()` | Active members | Zero receiver, zero capital, not a member | NO |
| `endGroup()` | Admin anytime; anyone after deadline | Not started, already ended, not expired (non-admin) | NO |
| `collectFees()` | Anyone | Never (returns 0 if nothing pending) | NO |

### ZybraGroup — Admin Functions

| Function | Who can call | When it reverts |
|---|---|---|
| `pause()` | Admin | Not admin |
| `unpause()` | Admin | Not admin |
| `transferAdmin()` | Admin | Zero address, not admin |
| `acceptAdmin()` | pendingAdmin | Not pending admin |
| `sweepToken()` | Admin | Group asset or vault share, zero balance, not admin |

### Treasury

| Function | Who can call | When it reverts |
|---|---|---|
| `deposit()` | COLLECTOR_ROLE | Zero address/amount |
| `withdraw()` | MANAGER_ROLE | Zero address/amount, insufficient balance |
| `withdrawAll()` | MANAGER_ROLE | Zero address, zero balance |
| `emergencyWithdraw()` | DEFAULT_ADMIN_ROLE | Zero address/amount |
| `grantRole()` | DEFAULT_ADMIN_ROLE | (standard OZ AccessControl rules) |

---

*Document generated for the Zybra Protocol audit. Refer to `test/ZybraProtocolPoC.t.sol` for executable counterparts of every scenario described above.*
