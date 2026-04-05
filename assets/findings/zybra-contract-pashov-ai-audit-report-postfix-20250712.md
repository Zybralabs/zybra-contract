# 🔐 Security Review — Zybra Protocol (Post-Fix Re-Audit)

---

## Scope

|                                  |                                                        |
| -------------------------------- | ------------------------------------------------------ |
| **Mode**                         | ALL (170 attack vectors, 4 parallel agents)            |
| **Files reviewed**               | `ZybraGroup.sol` · `ZybraGroupFactory.sol` · `ZrUSD.sol`<br>`FeeCollector.sol` · `Treasury.sol` · `MetaMorphoFactory.sol`<br>`IFeeSource.sol` · `ITreasury.sol` · `IZybraGroup.sol`<br>`MerkleProof.sol` · `PercentageMath.sol` · `SharesMathLib.sol`<br>`TimeWeightedCapital.sol` · `YieldMath.sol` · `Counter.sol` |
| **Confidence threshold (1-100)** | 75                                                     |

---

## Previous Audit Fixes — Verification

All 4 findings from the previous audit have been **verified as resolved**:

| # | Previous Finding | Status |
|---|---|---|
| 1 | `collectFees()` bypasses capital-reservation guard | ✅ Fixed — capital guard now mirrors `_autoCollectFees()` |
| 2 | `_accrueRewards()` uncapped yield allows flash-loan inflation | ✅ Fixed — `MAX_YIELD_PER_ACCRUAL_BPS` (10%) cap applied |
| 3 | `endGroup()` missing `nonReentrant` modifier | ✅ Fixed — `nonReentrant` added |
| 4 | Fee-on-transfer token accounting mismatch in `contribute()` | ✅ Fixed — balance-before/after check with `FeeOnTransferNotSupported` revert |

---

## New Findings

[100] **1. ZrUSD Unprotected `mint()` and `burn()` Allow Total Fund Theft**

`ZrUSD.mint` · `ZrUSD.burn` · Confidence: 100

**Description**
`mint(address to, uint256 assets)` and `burn(address from, uint256 assets)` are external functions with **zero access control**. Any EOA can: (a) call `mint(attacker, type(uint256).max)` to inflate `totalSupply` without depositing, diluting all ERC4626 share values; (b) call `burn(victim, victim.balanceOf())` to destroy any user's shares, permanently locking or stealing their underlying USDC via `redeem()`. These two paths compound — inflate to grief, burn to steal.

**Fix**

```diff
+ import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
+
- contract ZrUSD is ERC4626 {
-     constructor(address usdc) ERC20("Zybra Reserve Dollar", "ZrUSD") ERC4626(IERC20(usdc)) {}
+ contract ZrUSD is ERC4626, Ownable {
+     constructor(address usdc) ERC20("Zybra Reserve Dollar", "ZrUSD") ERC4626(IERC20(usdc)) Ownable(msg.sender) {}
 
-     function mint(address to, uint256 assets) external {
+     function mint(address to, uint256 assets) external onlyOwner {
          _mint(to, assets);
      }
 
-     function burn(address from, uint256 assets) external {
+     function burn(address from, uint256 assets) external {
+         require(msg.sender == from || allowance(from, msg.sender) >= assets, "ZrUSD: not authorized");
+         if (msg.sender != from) {
+             _spendAllowance(from, msg.sender, assets);
+         }
          _burn(from, assets);
      }
```

---

[85] **2. USDC-Blacklisted Member Funds Permanently Locked — No Alternative Receiver**

`ZybraGroup.withdraw` · `ZybraGroup.emergencyWithdraw` · Confidence: 85

**Description**
Both `withdraw()` and `emergencyWithdraw()` hardcode `msg.sender` as the receiver in `_safeVaultWithdraw(amount, msg.sender)`. If USDC blacklists a member address, every withdrawal path reverts when the vault's underlying `USDC.transfer(blacklistedAddress, ...)` fails, permanently locking that member's capital and yield with no escape hatch or receiver override.

**Fix**

```diff
- function withdraw() external nonReentrant whenNotPaused {
+ function withdraw(address receiver) external nonReentrant whenNotPaused {
+     if (receiver == address(0)) receiver = msg.sender;
      if (members[msg.sender].isActive != 1) revert NotMember();
      // ... existing logic ...
-     _safeVaultWithdraw(totalAmount, msg.sender);
+     _safeVaultWithdraw(totalAmount, receiver);

- function emergencyWithdraw() external nonReentrant {
+ function emergencyWithdraw(address receiver) external nonReentrant {
+     if (receiver == address(0)) receiver = msg.sender;
      // ... existing logic ...
-     _safeVaultWithdraw(capital, msg.sender);
+     _safeVaultWithdraw(capital, receiver);
```

---

[85] **3. FeeCollector Permanently DOSed for ZybraGroup Sources — Broken Integration**

`FeeCollector._collectFrom` · `ZybraGroup.collectFees` · Confidence: 85

**Description**
`ZybraGroup.collectFees()` withdraws fees from the vault and sends them **directly to the treasury** via `_safeVaultWithdraw(amount, _treasury)`. When `FeeCollector._collectFrom()` calls `source.collectFees()`, it receives a nonzero return value but **zero token balance** — the tokens went straight to the factory's treasury, not to the FeeCollector. The subsequent `treasury.deposit(asset, amount)` reverts on `safeTransferFrom(FeeCollector, treasury, amount)` because FeeCollector holds no tokens. This makes `collectFrom()` and `collectAll()` always revert for any ZybraGroup source with pending fees, DOSing all keeper-driven batch fee collection.

**Fix**

```diff
  // Option A: ZybraGroup.collectFees() sends to caller instead of hardcoded treasury
      totalFeesWithdrawn += amount;
  
-     address _treasury = treasury();
-     _safeVaultWithdraw(amount, _treasury);
-     emit FeesCollected(_treasury, amount);
+     _safeVaultWithdraw(amount, msg.sender);
+     emit FeesCollected(msg.sender, amount);

  // Option B: FeeCollector wraps treasury.deposit() in try/catch and checks balance
```

---

[80] **4. Emergency-Withdraw Forfeited Yield Permanently Locked in Vault**

`ZybraGroup.emergencyWithdraw` · Confidence: 80

**Description**
When a member calls `emergencyWithdraw()`, `_accrueRewards()` allocates their proportional yield into `accRewardPerShare` before the `Member` struct is zeroed. Because the member data is cleared without claiming the yield or redistributing it, that portion remains in the vault but is never recognized as new yield by the accumulator (already materialized into `lastMaterializedYield`). The NatSpec states "yield stays for other users," but the MasterChef accumulator does **not** redistribute it — remaining members receive only their own per-capital share. Orphaned yield permanently remains in the vault with no claim path.

**Fix**

```diff
  uint256 forfeitedYield = _pendingReward(m);

  // Clear member
  members[msg.sender] = Member(0, 0, 0, 0);
  activeMembersCount -= 1;
  totalCapitalInGroup -= capital;

+ // Send forfeited yield to treasury rather than leaving it orphaned
+ if (forfeitedYield > 0) {
+     totalDistributedYield += forfeitedYield;
+     address _treasury = treasury();
+     _safeVaultWithdraw(forfeitedYield, _treasury);
+     emit FeesCollected(_treasury, forfeitedYield);
+ }

  _safeVaultWithdraw(capital, msg.sender);
```

---

[80] **5. `pendingYield()` and `getMemberInfo()` View Functions Overstate Claimable Yield**

`ZybraGroup.pendingYield` · `ZybraGroup.getMemberInfo` · Confidence: 80

**Description**
`_accrueRewards()` caps `newYield` at `MAX_YIELD_PER_ACCRUAL_BPS` (10%) of `totalCapitalInGroup` per accrual to prevent flash-loan inflation. Both `pendingYield()` and `getMemberInfo()` simulate the accrual for live estimates but skip this cap entirely. When vault share price is elevated, these views return inflated values. On-chain integrators that read `pendingYield()` to size claims see a higher value than `claimYield()` delivers, breaking composability.

**Fix**

```diff
  // Inside pendingYield() — after computing newYield:
  if (totalEverYield > lastMaterializedYield) {
      uint256 newYield = totalEverYield - lastMaterializedYield;
+     // Mirror _accrueRewards cap
+     if (_totalCap > 0) {
+         uint256 maxYield = (_totalCap * MAX_YIELD_PER_ACCRUAL_BPS) / 10000;
+         if (newYield > maxYield) newYield = maxYield;
+     }
      uint256 fee = (newYield * PROTOCOL_FEE_BPS) / 10000;
```

*(Apply same fix inside `getMemberInfo()`.)*

---

## Findings List

| # | Confidence | Title |
|---|---|---|
| 1 | [100] | ZrUSD Unprotected `mint()` and `burn()` Allow Total Fund Theft |
| 2 | [85] | USDC-Blacklisted Member Funds Permanently Locked |
| 3 | [85] | FeeCollector Permanently DOSed for ZybraGroup Sources |
| 4 | [80] | Emergency-Withdraw Forfeited Yield Permanently Locked |
| 5 | [80] | `pendingYield()` / `getMemberInfo()` Overstate Claimable Yield |

---

> ⚠️ This review was performed by an AI assistant. AI analysis can never verify the complete absence of vulnerabilities and no guarantee of security is given. Team security reviews, bug bounty programs, and on-chain monitoring are strongly recommended. For a consultation regarding your projects' security, visit [https://www.pashov.com](https://www.pashov.com)
