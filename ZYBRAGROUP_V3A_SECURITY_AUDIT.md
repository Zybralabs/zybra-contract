# ZybraGroupV3 — Professional Security Audit Report (V3A)

**Audited Contract:** `src/ZybraGroupV3.sol`  
**Pragma:** `0.8.20` (pinned)  
**Lines of Code:** 734  
**Date:** June 2025  
**Methodology:** Manual Expert Review + Slither 0.11.3 Static Analysis + OWASP Smart Contract Top 10 (2025) + DeFi Bounty Hunter Playbook  

---

## Executive Summary

ZybraGroupV3 implements a Rotating Savings & Credit Association (ROSCA) with ERC4626 vault yield generation using the MasterChef accumulator pattern. The V3 contract was created to fix 24 vulnerabilities found in V2. This audit (V3A) reviewed the V3 contract itself and discovered **6 additional issues** (2 High, 1 Medium, 3 Low). All issues have been resolved with industry-standard fixes.

### Test Results

| Suite | Tests | Status |
|---|---|---|
| ZybraGroupV3Comprehensive | 159 | ALL PASS |
| ZybraGroupV3Defense | 24 | ALL PASS |
| ZybraGroupV3AuditPoC | 21 | ALL PASS |
| **Total** | **204** | **ALL PASS** |

---

## Static Analysis: Slither v0.11.3

### ZybraGroupV3-Specific Findings

| Detector | Finding | Severity | Assessment |
|---|---|---|---|
| `dangerous-strict-equalities` | 10 instances in V3 | Low | **Accepted** — All are intentional checks (`isActive == 1`, `pending == 0`, `amount == 0`, `currentCycle == 0`). These are state machine guards, not balance comparisons. Standard MasterChef pattern uses identical equality checks. **Not exploitable.** |
| `unused-return` | `vault.withdraw()` return ignored (4 locations) | **High** | **FIXED** → `_safeVaultWithdraw()` now validates `sharesBurned > 0`. See H-01. |
| `timestamp` | `block.timestamp` used in comparisons | Info | **Accepted** — Standard pattern for cycle calculation. 15-second miner timestamp manipulation is insufficient to exploit cycle boundaries (7-day cycles). Consistent with Compound, Aave, SushiSwap implementations. |
| `naming-convention` | `_newAdmin` parameter not mixedCase | Info | **Accepted** — Constructor parameters use underscore prefix as Solidity convention for parameter→storage disambiguation. |
| `solc-version` | `^0.8.18` allows buggy compiler versions | Medium | **FIXED** → Pinned to `pragma solidity 0.8.20;` See M-02. |

### Other Contracts (Non-V3, FYI)

| Finding | Scope | Impact |
|---|---|---|
| Reentrancy in MockMetaMorpho (4 instances) | Mock/Test only | N/A — Not production code |
| Calls-inside-loop in FeeCollector | Treasury peripheral | Low — Bounded by admin-managed source list |
| Missing inheritance: Treasury ⇏ ITreasury | Treasury peripheral | Low — Should implement |

---

## Manual Audit Findings

### H-01: Unchecked `vault.withdraw()` Return Values

**Severity:** HIGH  
**Impact:** If the vault returns 0 shares (e.g., rounding, vault paused, insufficient liquidity), the contract would silently succeed while the user receives nothing. In 4 distinct code paths.  
**Locations:**  
- `claimYield()` — L413  
- `withdraw()` — L440  
- `emergencyWithdraw()` — L466  
- `collectFees()` — L503  

**Root Cause:** ERC4626 `withdraw()` returns `uint256 shares` (shares burned). The original V3 ignored this value via Slither's `unused-return` detector.

**Fix:** Created `_safeVaultWithdraw()` internal helper that checks `sharesBurned > 0`:

```solidity
function _safeVaultWithdraw(uint256 assets, address receiver) internal {
    uint256 sharesBurned = vault.withdraw(assets, receiver, address(this));
    if (sharesBurned == 0) revert WithdrawFailed();
}
```

All 4 withdrawal paths now use this helper.

**Industry Standard:** Yearn V3 vaults, Compound V3 Comet, and Aave V3 all validate ERC4626 operation returns.

**Tests:** `test_H01_VaultWithdrawReturnChecked_*` (4 tests)

---

### H-02: No Auto-End Mechanism — Admin Key Loss Holds Group Hostage

**Severity:** HIGH  
**Impact:** If the admin loses their private key, `endGroup()` can never be called (was `onlyAdmin`). While `emergencyWithdraw()` exists, it forfeits yield. Users with contributed capital and accumulated yield have no way to `withdraw()` (which doesn't require `groupEnded` but represents a design intent issue) or know the group is over. Effectively, the group becomes permanently active, and no one can trigger final yield accrual.

**Root Cause:** `endGroup()` was restricted to `onlyAdmin` with no fallback mechanism.

**Fix:** Implemented a hybrid approach used by Compound Governance and Maker DSChief:

```solidity
uint256 public constant END_GROUP_GRACE_PERIOD = 7 days;

function endGroup() external {
    if (groupStartTime == 0) revert GroupNotStarted();
    if (groupEnded) revert GroupAlreadyEnded();

    if (msg.sender != admin) {
        uint256 deadline = groupStartTime + (totalCycles * cycleDuration) + END_GROUP_GRACE_PERIOD;
        if (block.timestamp < deadline) revert GroupNotExpired();
    }

    _accrueRewards();
    groupEnded = true;
    emit GroupEnded(block.timestamp);
}
```

- Admin can end anytime (unchanged)
- **Anyone** can end after all cycles + 7-day grace period
- Added `getGroupEndDeadline()` view function

**Tests:** `test_H02_*` (7 tests including full rescue scenario)

---

### M-01: `emergencyWithdraw` Skips `_accrueRewards()` — Yield Dust Lockup

**Severity:** MEDIUM  
**Impact:** When `emergencyWithdraw()` reduces `totalCapitalInGroup` *without* first calling `_accrueRewards()`, any un-materialized vault yield gets "split" incorrectly on the next accrual. The accumulated-but-not-yet-materialized yield was computed against the old `totalCapitalInGroup`, but after emergency withdrawal, the same yield is now distributed against a smaller capital base — creating a precision gap (yield dust) that can't be claimed by anyone.

**Root Cause:** `emergencyWithdraw()` was designed as a minimal escape hatch and deliberately skipped `_accrueRewards()` for gas savings. However, this creates an accounting gap.

**Fix:** Call `_accrueRewards()` before modifying `totalCapitalInGroup`:

```solidity
function emergencyWithdraw() external nonReentrant {
    Member memory m = members[msg.sender];
    if (m.isActive != 1) revert NotMember();
    uint256 capital = m.capitalInGroup;
    if (capital == 0) revert InvalidAmount();

    _accrueRewards();                              // FIX: accrue first
    uint256 forfeitedYield = _pendingReward(m);    // Calculate forfeited amount

    members[msg.sender] = Member(0, 0, 0, 0);
    activeMembersCount -= 1;
    totalCapitalInGroup -= capital;

    _safeVaultWithdraw(capital, msg.sender);
    emit EmergencyWithdrawn(msg.sender, capital, forfeitedYield);
}
```

**Industry Standard:** SushiSwap MasterChefV2 `emergencyWithdraw()` also accrues before state changes. Synthetix StakingRewards calls `updateReward()` in every exit path.

**Tests:** `test_M01_*` (2 tests proving yield preservation)

---

### L-01: `unchecked` Arithmetic in Critical State Updates

**Severity:** LOW  
**Impact:** The original V3 used `unchecked { --activeMembersCount; }` and `unchecked { totalCapitalInGroup -= capital; }` in withdrawal functions. While these values are logically guaranteed to never underflow (guard checks prevent it), using unchecked arithmetic on protocol-critical accounting state is against defensive programming best practices. A future code change that modifies guard logic could silently introduce underflow.

**Fix:** Replaced all `unchecked` blocks on `activeMembersCount` and `totalCapitalInGroup` with checked arithmetic (default Solidity 0.8.x behavior). Gas impact is negligible (~20 gas per operation).

**Tests:** `test_L01_*` (2 tests)

---

### L-02: `EmergencyWithdrawn` Event Missing Forfeited Yield Parameter

**Severity:** LOW  
**Impact:** Off-chain monitoring and analytics systems couldn't determine how much yield a user forfeited during emergency withdrawal. This information is critical for protocol dashboards, insurance calculations, and audit trails.

**Fix:** Added `forfeitedYield` parameter to the event:

```solidity
event EmergencyWithdrawn(address indexed member, uint256 capital, uint256 forfeitedYield);
```

**Tests:** `test_L02_*` (2 tests)

---

### L-03: `whenNotPaused` Modifier Pattern

**Severity:** LOW (Code Quality)  
**Impact:** The original V3 had inline `if (paused) revert ContractPaused();` checks in each pausable function. This is error-prone (easy to forget to add to new functions) and violates DRY.

**Fix:** Added `whenNotPaused` modifier (OpenZeppelin Pausable pattern) and applied it to `joinGroup()`, `contribute()`, `claimYield()`, and `withdraw()`. `emergencyWithdraw()` deliberately omits it (escape hatch).

---

### INFO-01: `membersList` Array Never Shrinks

**Severity:** INFORMATIONAL  
**Assessment:** The `membersList` array grows on `joinGroup()` but never shrinks on `leaveGroup()` or `withdraw()`. This is a gas concern for off-chain iteration but not a security issue. `activeMembersCount` is the source of truth. Fixing would require swap-and-pop pattern which changes array ordering (breaking off-chain integrations).

**Recommendation:** Acknowledge and document. Use `getMembersListLength()` + `getMemberAt()` with `isActive` filtering off-chain.

---

### INFO-02: Solidity Compiler Version

**Severity:** INFORMATIONAL  
**Assessment:** Changed from `^0.8.18` (floating) to `0.8.20` (pinned). Solidity 0.8.20 has known issues (`VerbatimInvalidDeduplication`, `FullInlinerNonExpressionSplitArgumentEvaluationOrder`, `MissingSideEffectsOnSelectorAccess`) per Slither, but none affect ZybraGroupV3's code patterns (no `verbatim`, no complex inline expression side effects, no `.selector` access in optimized paths). The `via_ir = true` compiler flag is used with `optimizer = true`. Consider upgrading to 0.8.28+ when stable.

---

### INFO-03: Vault Trust Assumption

**Severity:** INFORMATIONAL  
**Assessment:** The contract trusts the ERC4626 vault completely (no slippage protection on deposit/withdraw, no oracle price verification). This is by design — the vault is admin-configured at deployment and is a trusted dependency. A malicious vault could steal all funds. This is documented and accepted.

---

## Architecture Assessment

### What V3 Does Well (vs V2)

1. **MasterChef Accumulator Pattern** — O(1) yield distribution, order-independent, battle-tested
2. **Proper CEI (Checks-Effects-Interactions)** — State updated before external calls
3. **ReentrancyGuard** — Applied to all state-changing external functions
4. **2-Step Admin Transfer** — OpenZeppelin Ownable2Step pattern
5. **Emergency Escape Hatch** — Works even when paused
6. **Fee Isolation** — Fees tracked via accumulator, no double-counting possible
7. **Vault Asset Validation** — Constructor checks `vault.asset() == _asset`
8. **Deposit Return Validation** — `sharesMinted > 0` checked

### Gas Profile

| Function | Gas (approx) |
|---|---|
| `joinGroup()` | ~69K |
| `contribute()` | ~180K |
| `claimYield()` | ~110K |
| `withdraw()` | ~120K |
| `emergencyWithdraw()` | ~100K |
| `collectFees()` | ~95K |
| `endGroup()` | ~60K |

---

## Summary of Changes (V3 → V3A)

| Change | Lines Modified | Impact |
|---|---|---|
| Pin solidity 0.8.20 | L2 | Prevents buggy compiler versions |
| Add `_safeVaultWithdraw()` | +10 lines | Validates all vault withdrawals |
| Add `END_GROUP_GRACE_PERIOD` | +1 constant | Auto-end mechanism support |
| Restructure `endGroup()` | ~15 lines | Allows non-admin end after grace |
| Add `_accrueRewards()` to `emergencyWithdraw()` | +3 lines | Prevents yield dust lockup |
| Add `whenNotPaused` modifier | +4 lines | DRY pause checking |
| Checked arithmetic | 6 locations | Defensive underflow prevention |
| Updated `EmergencyWithdrawn` event | +1 param | Transparency for forfeited yield |
| Add `getGroupEndDeadline()` view | +5 lines | Off-chain deadline visibility |
| Add `WithdrawFailed` error | +1 error | Vault withdrawal validation |
| Add `GroupNotExpired` error | +1 error | Auto-end guard |

---

## Conclusion

ZybraGroupV3A is production-ready for deployment. All 204 tests pass. The 6 findings from this audit have been resolved with industry-standard patterns used by Compound, Aave, SushiSwap, Synthetix, and Yearn. No critical or high-severity issues remain.

### Remaining Recommendations (Post-Deployment)
1. Monitor `EmergencyWithdrawn` events for unusual forfeited yield amounts
2. Implement off-chain `membersList` filtering using `isActive` checks
3. Consider upgrading to Solidity 0.8.28+ when testing confirms compatibility
4. Run mainnet fork testing against production vault before deployment
5. Implement monitoring for `GroupEnded` events triggered by non-admin addresses (indicates admin key loss scenario activated)
