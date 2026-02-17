# ZybraGroup V2 - Capital-Weighted Yield Distribution

## Overview

ZybraGroup V2 is a **capital-weighted ROSCA** (Rotating Savings and Credit Association) with fair yield distribution based on capital contribution, not contribution action.

## Key Principles

### 1. **NO Catch-up Mechanism**
- Members can **ONLY** contribute for the current cycle
- Missing a cycle means you don't add new capital (your share gets diluted)
- This is intentional - **natural dilution** is the penalty

### 2. **Capital-Weighted Yield Distribution**
- **CRITICAL INSIGHT**: Yield belongs to capital, NOT to contribution action
- Members who don't contribute still get yield on their existing capital
- Why? Because their capital in the vault IS generating that yield
- Natural penalty: Your capital share shrinks relative to others who keep contributing

### 3. **Protocol Fees**
- 0% for first 40% of cycles
- Gradually increases to 10% by the last cycle
- Fees taken from yield only, never from capital

### 4. **Continuous Yield Claims**
- Members can claim accumulated yield anytime
- No Merkle tree, no payout order needed
- Simple and gas-efficient

## Architecture

### Core Files

```
contracts/src/
├── ZybraGroupV2.sol              # Main V2 contract
├── ZybraGroupFactoryV2.sol       # Factory for deploying V2 groups
└── libraries/
    ├── PercentageMath.sol        # Percentage & fee calculations
    └── YieldMath.sol             # Yield distribution logic
```

### Key Contracts

#### ZybraGroupV2.sol
**Location**: `contracts/src/ZybraGroupV2.sol`

**Key Functions**:
- `contribute()` - Contribute for current cycle only (no catch-up)
- `distributeYieldForCycle(uint256 cycle)` - Distribute yield to ALL members with capital
- `claimYield()` - Claim accumulated yield
- `emergencyWithdraw()` - Emergency exit with 3% penalty

**Critical Logic - Yield Distribution**:
```solidity
// Distribute yield to ALL members with capital (not just contributors)
for (uint256 i = 0; i < membersLength; i++) {
    address member = membersList[i];
    uint256 memberCapital = members[member].capitalInGroup;

    if (memberCapital > 0 && members[member].isActive) {
        // Member gets yield proportional to their capital
        uint256 memberYield = YieldMath.calculateMemberYield(
            distributableYield,
            memberCapital,
            totalCapitalInGroup
        );

        members[member].pendingYield += uint128(memberYield);
        emit YieldCredited(member, memberYield, cycle);
    }
}
```

**Why This Is Fair**:
- User A contributes: 100 USDC (total: 100)
- User B contributes: 100 USDC (total: 200)
- Vault generates 10 USDC yield
- User A gets: (10 × 100) / 200 = 5 USDC ✅
- User B gets: (10 × 100) / 200 = 5 USDC ✅

If User B skips next cycle:
- User A contributes: 100 USDC (total capital: 300)
- User B skips (total capital: 200)
- Total pool capital: 300
- Vault generates 15 USDC yield
- User A gets: (15 × 200) / 300 = 10 USDC ✅
- User B gets: (15 × 100) / 300 = 5 USDC ✅

**Natural Dilution**: User B's share went from 50% → 33% because they didn't contribute. This is the penalty.

#### Libraries

**PercentageMath.sol**:
- `calculateLinearFee()` - Protocol fee calculation (0% → 10%)
- `proportionalShare()` - Proportional distribution helper

**YieldMath.sol**:
- `calculateNewYield()` - New yield since last snapshot
- `calculateMemberYield()` - Member's proportional share
- `splitYield()` - Split between protocol and members
- `calculateWithdrawalWithPenalty()` - Emergency withdrawal with 3% penalty

## Deployment

### Script
**File**: `contracts/script/DeploySepoliaV2.s.sol`

```bash
forge script script/DeploySepoliaV2.s.sol:DeploySepoliaV2 \
  --rpc-url https://ethereum-sepolia-rpc.publicnode.com \
  --broadcast \
  --legacy
```

### Sepolia Addresses
- **USDC**: `0x9d60E70d6d164708397E7F0aBa139589c7447255`
- **Morpho Vault**: `0xe1872D62bA3342BB34Df13f5Ba542C667841395E`

## User Flow

### Setup Phase
1. **Deploy Factory** (one-time)
   ```solidity
   ZybraGroupFactoryV2 factory = new ZybraGroupFactoryV2();
   ```

2. **Deploy Group via Factory**
   ```solidity
   address group = factory.deployGroup(
       USDC,           // asset
       100e6,          // 100 USDC per cycle
       1 weeks,        // cycle duration
       5,              // 5 cycles
       admin,          // admin address
       MORPHO_VAULT    // vault address
   );
   ```

3. **Members Join**
   ```solidity
   group.joinGroup(memberAddress);
   ```

4. **Start Group**
   ```solidity
   group.startGroup();
   ```

### Active Phase
5. **Members Contribute** (each cycle)
   ```solidity
   // Approve USDC first
   usdc.approve(address(group), 100e6);

   // Contribute
   group.contribute(); // Only for current cycle
   ```

6. **Distribute Yield** (after cycle ends)
   ```solidity
   // Anyone can call this (public good)
   group.distributeYieldForCycle(1);
   ```

7. **Members Claim Yield** (anytime)
   ```solidity
   group.claimYield();
   ```

## State Variables

```solidity
// Member tracking
address[] public membersList;              // All members
mapping(address => Member) public members; // Member details

struct Member {
    uint128 capitalInGroup;          // Total capital contributed
    uint128 pendingYield;            // Unclaimed yield
    uint64 lastContributedCycle;     // Last cycle contributed
    uint64 joinedAt;                 // Join timestamp
    bool isActive;                   // Active status
}

// Group state
uint256 public totalCapitalInGroup;     // Total capital from all members
uint256 public lastYieldSnapshot;      // Last recorded total yield

// Per-cycle tracking
mapping(uint256 => uint256) public cycleYieldGenerated;
mapping(uint256 => bool) public cycleYieldDistributed;
mapping(address => mapping(uint256 => bool)) public contributedInCycle;
```

## Events

```solidity
event Joined(address indexed member);
event Contributed(address indexed member, uint256 amount, uint256 cycle, uint256 totalCapital);
event YieldDistributed(uint256 cycle, uint256 totalYield, uint256 eligibleCapital);
event YieldCredited(address indexed member, uint256 amount, uint256 cycle);
event YieldClaimed(address indexed member, uint256 amount);
event EmergencyWithdrawn(address indexed member, uint256 amount, uint256 penalty);
event ProtocolFeeCollected(uint256 amount, uint256 cycle);
```

## Gas Optimizations

1. **Packed Storage**: Member struct uses uint128/uint64 for gas savings
2. **Batch Distribution**: `batchDistributeYield()` for multiple cycles
3. **Unchecked Loops**: Safe arithmetic optimizations
4. **Member List**: Direct array iteration (no mapping iteration)

## Security Features

1. **Reentrancy Guard**: Custom implementation
2. **SafeERC20**: All token transfers use SafeERC20
3. **Input Validation**: Comprehensive parameter validation
4. **Pause Mechanism**: Admin can pause in emergencies
5. **Emergency Withdraw**: 3% penalty for early exit

## Constants

```solidity
uint256 public constant MAX_MEMBERS = 50;
uint256 public constant MIN_CONTRIBUTION = 1e6;        // 1 USDC
uint256 public constant MAX_CONTRIBUTION = 1000e6;     // 1000 USDC
uint256 public constant PENALTY_BPS = 300;             // 3%
uint256 public constant PROTOCOL_FEE_START_PERCENTILE = 40; // 40%
uint256 public constant PROTOCOL_MAX_FEE_BPS = 1000;   // 10%
```

## Comparison: V1 vs V2

| Feature | V1 (ZybraGroup) | V2 (ZybraGroupV2) |
|---------|----------------|-------------------|
| **Yield Model** | Winner-takes-all (Merkle) | Capital-weighted |
| **Catch-up** | Yes (with 2% penalty) | No |
| **Yield Distribution** | One winner per cycle | All capital holders |
| **Claims** | One-time per cycle | Continuous |
| **Payout Order** | Required (Merkle tree) | Not needed |
| **Fairness** | First few members get most | Proportional to capital |
| **Gas Efficiency** | Merkle proof overhead | Direct distribution |

## Example Scenario

### 5-Member Group, 5 Cycles, 100 USDC per cycle

**Cycle 1**:
- All 5 members contribute: 100 USDC each
- Total capital: 500 USDC
- Vault generates: 5 USDC
- Each member gets: (5 × 100) / 500 = 1 USDC

**Cycle 2**:
- Members A, B, C contribute: 100 USDC each
- Members D, E skip
- Total capital: 800 USDC (D and E still have 100 each)
- Vault generates: 8 USDC
- A, B, C get: (8 × 200) / 800 = 2 USDC each
- D, E get: (8 × 100) / 800 = 1 USDC each

**D and E's capital share**: Was 20% (100/500), now 12.5% (100/800) - **DILUTED**

**Cycle 3**:
- Protocol fees start (after 40% = 2 cycles)
- Fee = 3.33% (gradual increase)
- Members continue as desired...

**Final Cycle**:
- Protocol fee = 10% (maximum)
- All yield distributed
- Members can claim anytime

## Testing

### Build V2 Contracts
```bash
cd contracts
forge build --skip test
```

### Run Tests (when fixed)
```bash
forge test --match-contract ZybraGroupV2
```

## Summary of Changes from Previous Session

✅ **Fixed yield distribution logic**: Now distributes to ALL capital holders, not just contributors
✅ **Added helper libraries**: PercentageMath and YieldMath for cleaner code
✅ **Gas optimizations**: Packed storage, unchecked loops, batch operations
✅ **Created Factory V2**: ZybraGroupFactoryV2 for deploying V2 groups
✅ **Deployment script**: DeploySepoliaV2.s.sol ready to use
✅ **Added view functions**: membersCount(), getMembersListLength(), getMemberAt()

## Key Insight from User

> "YIELD BELONGS TO CAPITAL, NOT TO 'CONTRIBUTION ACTION'"

This principle drives the V2 design. Members who don't contribute still earn yield on their existing capital because that capital IS generating the yield. The natural penalty is **dilution** - their share shrinks as others contribute and grow their capital.

This is fair, sustainable, and aligns incentives properly.
