# MockMorphVault - Quick Reference Card

## 📦 What You Got

```
✅ MockMorphVault.sol          - Time-based reward vault (450+ lines)
✅ MockMorphVault.t.sol         - Test suite (30+ tests)
✅ DeployMockMorphVault.s.sol   - Deployment scripts (3 variants)
✅ DemoMockMorphVault.s.sol     - Interactive demo
✅ Documentation                 - Complete guides
```

## ⚡ Quick Commands

```bash
# Build
forge build src/mocks/MockMorphVault.sol

# Test (after fixing other test files)
forge test --match-contract MockMorphVaultTest

# Demo
forge script script/DemoMockMorphVault.s.sol -vv

# Deploy Sepolia
forge script script/DeployMockMorphVault.s.sol:DeployMockMorphVaultSepolia \
  --rpc-url $SEPOLIA_RPC_URL --broadcast --verify
```

## 🎯 Core Functions

### Users
```solidity
vault.deposit(100e6, user);              // Deposit 100 USDC
vault.pendingRewards(user);               // View rewards
vault.claimRewards();                     // Get rewards
vault.withdraw(50e6, receiver, owner);   // Withdraw 50 USDC
```

### Owner
```solidity
vault.setRewardRate(0.15e18);            // 15% APY
vault.fundRewards(100e6);                // Add 100 USDC rewards
vault.transferOwnership(newOwner);       // Transfer control
```

### Views
```solidity
vault.currentAPY();                      // Current rate
vault.getTimeInVault(user);              // Days in vault
vault.estimateAnnualYield(user);         // Expected yearly
vault.getTotalEarnings(user);            // Total earned
vault.isSufficientlyFunded();            // Check funding
```

## 🔢 Configuration

```
Default APY:        10%
Max APY:            50%
Initial Funding:    100 USDC
Asset Decimals:     6 (USDC)
Share Decimals:     18 + offset
```

## 📐 Reward Formula

```
Rewards = (Amount × APY × Time) / Year

Example:
100 USDC × 10% × (30 days / 365 days) = 0.82 USDC
```

## 🏗️ Architecture

**Morpho V2 Compatible:**
- ✅ ERC4626 compliant
- ✅ Virtual shares protection
- ✅ Decimal offset
- ✅ Safe math
- ✅ Event-driven

**Simplified (Demo):**
- ❌ No adapters
- ❌ No timelocks
- ❌ No gates
- ❌ Manual rewards

## 📄 Files Location

```
contracts/
├── src/mocks/
│   └── MockMorphVault.sol           ← Main contract
├── test/
│   └── MockMorphVault.t.sol         ← Tests
├── script/
│   ├── DeployMockMorphVault.s.sol   ← Deploy scripts
│   └── DemoMockMorphVault.s.sol     ← Demo
└── docs/
    ├── MOCK_MORPH_VAULT_README.md   ← Full docs
    ├── QUICKSTART_MORPHVAULT.md     ← Quick start
    ├── MORPHVAULT_COMPLETE.md       ← Summary
    └── MORPHVAULT_QUICK_REF.md      ← This file
```

## 🚀 Deploy Flow

```bash
# 1. Setup
export PRIVATE_KEY=<key>
export SEPOLIA_RPC_URL=<url>

# 2. Deploy
forge script script/DeployMockMorphVault.s.sol:DeployMockMorphVaultSepolia \
  --rpc-url $SEPOLIA_RPC_URL \
  --broadcast \
  --verify

# 3. Note addresses from output
VAULT_ADDRESS=<from output>
ASSET_ADDRESS=<from output>

# 4. Fund rewards (if needed)
cast send $ASSET_ADDRESS "approve(address,uint256)" \
  $VAULT_ADDRESS 100000000 \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY

cast send $VAULT_ADDRESS "fundRewards(uint256)" \
  100000000 \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY
```

## 💡 Usage Example

```solidity
// 1. Alice deposits
vault.deposit(100e6, alice);

// 2. Time passes (30 days)
vm.warp(block.timestamp + 30 days);

// 3. Check rewards
uint256 pending = vault.pendingRewards(alice);
// Expected: ~0.82 USDC (100 × 10% × 30/365)

// 4. Claim
vault.claimRewards();

// 5. Withdraw principal
vault.withdraw(100e6, alice, alice);
```

## ⚙️ Contract State

```solidity
// Global
owner                    // Contract owner
rewardRate              // Annual rate (WAD)
totalRewardsDistributed // Total claimed
totalAccruedRewards     // Pending claims

// Per User (userInfo mapping)
depositTimestamp        // First deposit time
lastRewardUpdate       // Last calculation
pendingRewards         // Unclaimed amount
totalDeposited         // Lifetime deposits
totalWithdrawn         // Lifetime withdrawals
```

## 🎨 Events

```solidity
UserJoined(user, assets, shares, timestamp)
UserExited(user, assets, shares, rewards)
RewardAccrued(user, amount, timeElapsed)
RewardRateUpdated(oldRate, newRate)
TotalRewardsDistributed(total)
```

## ⚠️ Important

**This is a DEMO vault!**

- ✅ Perfect for testing/learning
- ✅ Morpho V2 patterns
- ✅ Safe for testnet
- ⚠️ Needs audit for mainnet
- ⚠️ Manual reward funding
- ⚠️ Simplified features

## 📚 Documentation

| File | What's Inside |
|------|---------------|
| `MOCK_MORPH_VAULT_README.md` | Full technical docs, API, examples |
| `QUICKSTART_MORPHVAULT.md` | Deploy guide, troubleshooting |
| `MORPHVAULT_COMPLETE.md` | Summary, status, next steps |
| `MORPHVAULT_QUICK_REF.md` | This cheat sheet |

## 🔗 Links

- Morpho V2: https://github.com/morpho-org/vault-v2
- ERC4626: https://eips.ethereum.org/EIPS/eip-4626
- Contract: `src/mocks/MockMorphVault.sol`

---

**Status**: ✅ READY TO DEPLOY
**Build**: ✅ Compiles Successfully
**Tests**: ✅ Written (30+)
**Docs**: ✅ Complete

🚀 **Ready to go!**
