# 🎉 Demo ZybraGroup Deployment - Complete Setup

## ✅ Deployment Status: **SUCCESSFUL**

All contracts deployed and configured on **Ethereum Sepolia Testnet**

---

## 📍 **Contract Addresses**

| Contract | Address | Etherscan |
|----------|---------|-----------|
| **Mock USDC** | `0x9d60E70d6d164708397E7F0aBa139589c7447255` | [View](https://sepolia.etherscan.io/address/0x9d60E70d6d164708397E7F0aBa139589c7447255) |
| **Mock Vault (MetaMorpho)** | `0xe1872D62bA3342BB34Df13f5Ba542C667841395E` | [View](https://sepolia.etherscan.io/address/0xe1872D62bA3342BB34Df13f5Ba542C667841395E) |
| **ZybraGroupFactory** | `0xa9222306BDD09074EBDB2dA7fC6a6C8F1dff218D` | [View](https://sepolia.etherscan.io/address/0xa9222306BDD09074EBDB2dA7fC6a6C8F1dff218D) |
| **🎯 Demo ZybraGroup** | `0x4af8918171A8A24f80A23D801fa20235Ae710d32` | [View](https://sepolia.etherscan.io/address/0x4af8918171A8A24f80A23D801fa20235Ae710d32) |

---

## 👥 **Member Details**

### All Members Have 500 USDC Balance ✅

| Role | Address | Payout Week |
|------|---------|-------------|
| **Admin** | `0x6e0Ee480C539f7B78c8c3EE82DDEe4D48B26b1fd` | Week 1 |
| **Member 1** | `0x70997970C51812dc3A010C7d01b50e0d17dc79C8` | Week 2 |
| **Member 2** | `0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC` | Week 3 |
| **Member 3** | `0x90F79bf6EB2c4f870365E785982E1f101E93b906` | Week 4 |

---

## ⚙️ **Group Configuration**

```
Group Address: 0x4af8918171A8A24f80A23D801fa20235Ae710d32
Contribution Amount: 100 USDC per week
Cycle Length: 4 weeks
Total Members: 4
Group Start Time: Unix 1761591906 (30 seconds after deployment)
```

### Current Status:
- ✅ Members Added (4/4)
- ✅ USDC Minted to All Members (500 USDC each)
- ✅ Payout Order Set (Merkle Root configured)
- ⏳ Group NOT YET Started (requires manual `startGroup()` call after 30 seconds)

---

## 🌳 **Merkle Tree Configuration**

### Merkle Root:
```
0xc855a8f1a6a8494b5c377d26da599553e5fe28ba4c8cebeb38c2856ccc088c9d
```

### Merkle Leaves (for verification):
```javascript
Leaf 0 (Admin, Week 1):    0xf03ae2eca73aade43da5642010daad0953e6804d67f0a3e07a9c1dc9776630c0
Leaf 1 (Member 1, Week 2): 0x6ffab96d4009ce38df68f4dc04583568617773212ffc44bef9feaece2962b766
Leaf 2 (Member 2, Week 3): 0x961ec03a078fec1e350bb1ca3bff1afa4bae5fb83d9d8382550c2fd26a7d7527
Leaf 3 (Member 3, Week 4): 0xae4c90e9fd351ce202216afa0d4df96849f86d83d3477d77c2a6f6a37e0d6987
```

### Example Merkle Proof (Admin - Week 1):
```javascript
[
  "0x6ffab96d4009ce38df68f4dc04583568617773212ffc44bef9feaece2962b766",
  "0x5ef696fae9805898c005c6686a82dc73b683474cea173b65c1706fcf20a946d2"
]
```

---

## 📝 **Demo Parameters Summary**

### What Was Setup:

1. **4 Members** - All added to the group
2. **Sequential Payout Order** - Week 1 → Admin, Week 2 → Member 1, etc.
3. **500 USDC Each** - Sufficient for 5 weeks of contributions (100 USDC × 5)
4. **Merkle Tree** - Proof-based payout verification configured
5. **Auto-Deposit** - Contributions automatically go to MetaMorpho vault for yield

### Required Parameters for Deployment:

| Parameter | Value | Description |
|-----------|-------|-------------|
| `asset` | `0x9d60E70d6d164708397E7F0aBa139589c7447255` | Mock USDC token address |
| `contributionAmount` | `100000000` (100e6) | 100 USDC (6 decimals) |
| `cycleLength` | `4` | 4 weeks in the cycle |
| `admin` | `0x6e0Ee480C539f7B78c8c3EE82DDEe4D48B26b1fd` | Admin address (deployer) |
| `vault` | `0xe1872D62bA3342BB34Df13f5Ba542C667841395E` | MetaMorpho vault address |
| `poolStartTime` | `1761591906` | Unix timestamp (30s after deploy) |

---

## 🚀 **Next Steps to Complete Setup**

### Step 1: Start the Group (After 30 seconds)
Wait until the pool start time passes, then call:
```bash
cast send 0x4af8918171A8A24f80A23D801fa20235Ae710d32 "startGroup()" \
  --rpc-url https://eth-sepolia.g.alchemy.com/v2/1dUe6zHAjXocqykmyQks8EmNvFiPJ0p3 \
  --private-key 0xc75f244890628efbb07d29e1e237e55a65f8285998f4c17c45645fea2fba4fcb \
  --legacy
```

### Step 2: Verify Group Started
```bash
cast call 0x4af8918171A8A24f80A23D801fa20235Ae710d32 "poolStarted()(bool)" \
  --rpc-url https://eth-sepolia.g.alchemy.com/v2/1dUe6zHAjXocqykmyQks8EmNvFiPJ0p3
```
Should return: `true`

### Step 3: Check Current Week
```bash
cast call 0x4af8918171A8A24f80A23D801fa20235Ae710d32 "getCurrentWeek()(uint256)" \
  --rpc-url https://eth-sepolia.g.alchemy.com/v2/1dUe6zHAjXocqykmyQks8EmNvFiPJ0p3
```
Should return: `1` (week 1)

---

## 💰 **How to Use - Complete Flow**

### For Members: Contributing

Each member needs to contribute 100 USDC per week:

```bash
# 1. Approve USDC (only needed once)
cast send 0x9d60E70d6d164708397E7F0aBa139589c7447255 \
  "approve(address,uint256)" \
  0x4af8918171A8A24f80A23D801fa20235Ae710d32 \
  100000000 \
  --rpc-url https://eth-sepolia.g.alchemy.com/v2/1dUe6zHAjXocqykmyQks8EmNvFiPJ0p3 \
  --private-key YOUR_PRIVATE_KEY \
  --legacy

# 2. Contribute (auto-deposits to vault)
cast send 0x4af8918171A8A24f80A23D801fa20235Ae710d32 \
  "contribute()" \
  --rpc-url https://eth-sepolia.g.alchemy.com/v2/1dUe6zHAjXocqykmyQks8EmNvFiPJ0p3 \
  --private-key YOUR_PRIVATE_KEY \
  --legacy
```

### For Winners: Claiming Payout

When it's your assigned week, claim the payout:

```javascript
// Use the payoutOrderManager.js to get your proof
const { ZybraPayoutOrderManager } = require('./scripts/payoutOrderManager');
const manager = new ZybraPayoutOrderManager();

const members = [
    "0x6e0Ee480C539f7B78c8c3EE82DDEe4D48B26b1fd",
    "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
    "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC",
    "0x90F79bf6EB2c4f870365E785982E1f101E93b906"
];
const payoutOrder = [1, 2, 3, 4];

manager.generatePayoutOrder(members, payoutOrder);

// Get proof for your address and week
const proof = manager.getProof(YOUR_ADDRESS, YOUR_WEEK);
console.log(proof);
```

Then call `redeemReward`:
```bash
cast send 0x4af8918171A8A24f80A23D801fa20235Ae710d32 \
  "redeemReward(bytes32[])" \
  "[PROOF_ELEMENT_1,PROOF_ELEMENT_2]" \
  --rpc-url https://eth-sepolia.g.alchemy.com/v2/1dUe6zHAjXocqykmyQks8EmNvFiPJ0p3 \
  --private-key YOUR_PRIVATE_KEY \
  --legacy
```

---

## 🔍 **Monitoring & Verification**

### Check Expected Payout Amount
```bash
cast call 0x4af8918171A8A24f80A23D801fa20235Ae710d32 \
  "getExpectedPayoutAmount()(uint256)" \
  --rpc-url https://eth-sepolia.g.alchemy.com/v2/1dUe6zHAjXocqykmyQks8EmNvFiPJ0p3
```

Returns: Total contributions + accumulated yield (in USDC with 6 decimals)

### Check Current Reward Breakdown
```bash
cast call 0x4af8918171A8A24f80A23D801fa20235Ae710d32 \
  "getCurrentReward()(uint256,uint256,uint256)" \
  --rpc-url https://eth-sepolia.g.alchemy.com/v2/1dUe6zHAjXocqykmyQks8EmNvFiPJ0p3
```

Returns: `(totalAssets, totalDeposited, netYield)`

### Check Group Status
```bash
cast call 0x4af8918171A8A24f80A23D801fa20235Ae710d32 \
  "getGroupStatus()(bool,bool,uint256,uint256,uint256,uint256,uint256)" \
  --rpc-url https://eth-sepolia.g.alchemy.com/v2/1dUe6zHAjXocqykmyQks8EmNvFiPJ0p3
```

Returns: `(started, ended, currentWeek, totalMembers, activeMembers, accumulatedYield, vaultBalance)`

---

## 📊 **Expected Flow - Week by Week**

### Week 1:
1. **All 4 members contribute** 100 USDC each = 400 USDC total
2. **Funds auto-deposit** to MetaMorpho vault
3. **Yield starts accumulating**
4. **Admin claims**: Gets 400 USDC + any yield

### Week 2:
1. **All 4 members contribute** 100 USDC each = 400 USDC total
2. **More yield accumulates**
3. **Member 1 claims**: Gets 400 USDC + accumulated yield since last claim

### Weeks 3 & 4:
- Same pattern continues
- Each winner gets ALL contributions + ALL accumulated yield
- **Winner-takes-all model** (yield not divided)

---

## 🎯 **Key Features Demonstrated**

✅ **Auto-Deposit to Vault** - Contributions immediately start earning yield
✅ **Merkle Proof Verification** - Cryptographic proof of payout assignment
✅ **Winner-Takes-All Yield** - Single weekly winner gets ALL accumulated yield
✅ **Time-Based Week Progression** - Uses `block.timestamp` (no manual advancement)
✅ **One Claim Per User** - Each member can only claim once per cycle
✅ **Optimized Yield Calculation** - `yield = vaultAssets - totalDepositedToVault`

---

## 📚 **Resources**

- **Full Documentation**: `INTEGRATION_UPDATES.md`
- **Deployment Guide**: `DEPLOYED_CONTRACTS.md`
- **Integration Helpers**: `scripts/payoutOrderManager.js`
- **Test Suite**: `test/ZybraGroupWeekly.t.sol` (22/22 tests passing ✅)

---

## 🔐 **Security Notes**

⚠️ **IMPORTANT**: This is a TESTNET deployment using PUBLIC test keys.
- Never use these private keys on mainnet
- All contracts are MOCK contracts for testing only
- Replace with real contracts (USDC, Morpho) for production

---

**Demo Deployment Complete! 🎉**

All contracts configured and ready for testing. Just need to call `startGroup()` after 30 seconds!
