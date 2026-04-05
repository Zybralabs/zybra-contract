# 🔐 Security Review — ZybraGroupFactory & ZybraGroup

---

## Scope

|                                  |                                                        |
| -------------------------------- | ------------------------------------------------------ |
| **Mode**                         | DEEP (all in-scope files + adversarial reasoning)      |
| **Files reviewed**               | `ZybraGroupFactory.sol` · `ZybraGroup.sol`<br>`Treasury.sol` · `FeeCollector.sol` · `IFeeSource.sol` |
| **Confidence threshold (1-100)** | 75                                                     |

---

## Findings

[80] **1. `collectFees()` Bypasses Capital-Reservation Guard — Fees Can Drain User Principal**

`ZybraGroup.collectFees` · Confidence: 80

**Description**

`_autoCollectFees()` correctly caps fee withdrawal at `maxWithdrawable - totalCapitalInGroup`, ensuring member capital is never drained for fees. However, the permissionless `collectFees()` caps only at `maxWithdrawable` (the full vault value), omitting the capital reservation. When the vault suffers a value loss (bad debt, exploit, market event, depeg) and `vaultValue < totalCapitalInGroup`, previously-accumulated but uncollected fees are withdrawn from user principal.

**Attack path:**
1. Group operates normally; `_accrueRewards()` accumulates `totalAccumulatedFees = F` from historical yield.
2. `_autoCollectFees()` collects most fees, but some remain uncollected (below `MIN_FEE_AUTO_COLLECT` threshold, or auto-collect failed silently via `try/catch`).
3. Vault suffers a value loss → `vaultValue < totalCapitalInGroup`.
4. `_autoCollectFees()` correctly refuses: `withdrawableForFees = maxWithdrawable - _totalCap = 0`.
5. Anyone calls `collectFees()`:
   - `amount = totalAccumulatedFees - totalFeesWithdrawn` → positive stale value.
   - `maxWithdrawable = vaultValue` (< `totalCapitalInGroup`).
   - `amount ≤ maxWithdrawable` → **passes cap** (no capital reservation).
   - `_safeVaultWithdraw(amount, treasury)` → **withdraws user capital** to treasury.
6. Members collectively cannot recover full principal on `withdraw()`.

**Fix**

```diff
 function collectFees() external nonReentrant returns (uint256 amount) {
     _accrueRewards();

     amount = totalAccumulatedFees > totalFeesWithdrawn
         ? totalAccumulatedFees - totalFeesWithdrawn
         : 0;

     if (amount == 0) return 0;

     uint256 vaultShares = vault.balanceOf(address(this));
     uint256 maxWithdrawable = vaultShares > 0 ? vault.convertToAssets(vaultShares) : 0;
-    if (amount > maxWithdrawable) {
-        amount = maxWithdrawable;
-    }
+    // Reserve member capital — mirror _autoCollectFees() guard
+    uint256 _totalCap = totalCapitalInGroup;
+    uint256 withdrawableForFees = maxWithdrawable > _totalCap ? maxWithdrawable - _totalCap : 0;
+    if (amount > withdrawableForFees) {
+        amount = withdrawableForFees;
+    }
     if (amount == 0) return 0;

     totalFeesWithdrawn += amount;
     address _treasury = treasury();
     _safeVaultWithdraw(amount, _treasury);
     emit FeesCollected(_treasury, amount);
 }
```

---

[75] **2. Spot `vault.convertToAssets` in `_accrueRewards` Enables Flash-Loan Vault Share Price Inflation**

`ZybraGroup._accrueRewards` · Confidence: 75

**Description**

`_accrueRewards()` derives yield from a single-block spot call to `vault.convertToAssets()` with no time-weighting, oracle cross-check, or per-accrual yield cap. An attacker who can temporarily inflate the vault's share price (e.g., via donation to a vault using `balanceOf`-based accounting) can permanently inflate `accRewardPerShare` and `totalAccumulatedFees`. Once `lastMaterializedYield` is set to the inflated total, the condition `totalEverYield <= lastMaterializedYield` prevents any correction — the phantom yield becomes permanently claimable, draining real capital from other members.

**Fix**

```diff
 function _accrueRewards() internal {
     uint256 _totalCap = totalCapitalInGroup;
     uint256 vaultShares = vault.balanceOf(address(this));
     uint256 vaultValue = vaultShares > 0 ? vault.convertToAssets(vaultShares) : 0;
     uint256 vaultYield = vaultValue > _totalCap ? vaultValue - _totalCap : 0;
     uint256 totalEverYield = vaultYield + totalDistributedYield + totalFeesWithdrawn;
     if (totalEverYield <= lastMaterializedYield) return;
     uint256 newYield = totalEverYield - lastMaterializedYield;
+
+    // Cap single-accrual yield to prevent flash-loan inflation
+    // Max plausible yield per accrual: 10% of total capital
+    if (_totalCap > 0) {
+        uint256 maxYieldPerAccrual = _totalCap / 10;
+        if (newYield > maxYieldPerAccrual) {
+            newYield = maxYieldPerAccrual;
+            totalEverYield = lastMaterializedYield + newYield;
+        }
+    }
+
     if (_totalCap == 0) {
         totalAccumulatedFees += newYield;
         lastMaterializedYield = totalEverYield;
         _autoCollectFees();
         return;
     }
```

---

[55] **3. `endGroup()` Missing `nonReentrant` — Cross-Function Reentrancy via Vault Callback**

`ZybraGroup.endGroup` · Confidence: 55

**Description**

`endGroup()` calls `_accrueRewards()` → `_autoCollectFees()` → `vault.withdraw()` without the `nonReentrant` modifier. Since the reentrancy lock is never acquired, a vault with callback behavior (non-standard ERC4626, ERC-777 asset, or hook-enabled token) could re-enter any `nonReentrant`-protected function (`withdraw()`, `claimYield()`, `contribute()`, `collectFees()`) during the external call. Standard MetaMorpho vaults do not have callbacks, limiting exploitability to non-standard vault/token combinations.

---

[60] **4. Fee-on-Transfer Token Accounting Mismatch**

`ZybraGroup.contribute` · Confidence: 60

**Description**

`contribute()` records the fixed `contributionAmount` as capital and deposits that same nominal value to the vault without measuring actual tokens received after `safeTransferFrom`. If the group is deployed with a fee-on-transfer or deflationary token (the factory's `deployGroup` is permissionless and accepts any ERC-20 address), the contract receives fewer tokens than recorded, causing `totalCapitalInGroup` to exceed actual holdings over time.

---

Findings List

| # | Confidence | Title |
|---|---|---|
| 1 | [80] | `collectFees()` bypasses capital-reservation guard — fees can drain user principal |
| 2 | [75] | Spot `vault.convertToAssets` enables flash-loan vault share price inflation |
| | | **Below Confidence Threshold** |
| 3 | [55] | `endGroup()` missing `nonReentrant` — cross-function reentrancy via vault callback |
| 4 | [60] | Fee-on-transfer token accounting mismatch in `contribute()` |

---

> ⚠️ This review was performed by an AI assistant. AI analysis can never verify the complete absence of vulnerabilities and no guarantee of security is given. Team security reviews, bug bounty programs, and on-chain monitoring are strongly recommended. For a consultation regarding your projects' security, visit [https://www.pashov.com](https://www.pashov.com)
