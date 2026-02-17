# ZybraGroup V2 - Professional DeFi Product

## Overview
ZybraGroup V2 is a capital-weighted ROSCA (Rotating Savings and Credit Association) with proportional yield distribution built on ERC4626 vaults.

## Architecture

### Core Components

#### 1. **Main Contract: ZybraGroupV2**
- Manages pool lifecycle and member operations
- Orchestrates yield distribution
- Handles contributions and withdrawals
- Implements admin controls

#### 2. **PercentageMath Library**
Provides gas-optimized mathematical operations:
- `percentMul()`: Percentage calculation with rounding
- `percentMulFloor()`: Percentage calculation without rounding
- `calculateLinearFee()`: Linear fee progression (0% → 10%)
- `proportionalShare()`: Capital-weighted distribution

#### 3. **YieldMath Library**
Specialized yield calculation functions:
- `calculateNewYield()`: Incremental yield tracking
- `calculateMemberYield()`: Proportional yield allocation
- `splitYield()`: Protocol fee separation
- `calculateWithdrawalWithPenalty()`: Emergency withdrawal math

## Gas Optimizations

### Storage Packing
```solidity
struct Member {
    uint128 capitalInGroup;          // Slot 1 (16 bytes)
    uint128 pendingYield;            // Slot 1 (16 bytes)
    uint64 lastContributedCycle;     // Slot 2 (8 bytes)
    uint64 joinedAt;                 // Slot 2 (8 bytes)
    bool isActive;                   // Slot 2 (1 byte)
}
// Total: 2 storage slots vs 5 slots (60% reduction)
```

### Loop Optimizations
- **membersList array**: O(n) iteration instead of mapping scan
- **unchecked increment**: `unchecked { ++i; }` saves ~30 gas per iteration
- **Batch operations**: Process multiple cycles in single transaction

### Library Usage
- Reusable code reduces deployment size
- Inline optimization by compiler
- Clear separation of concerns

## Key Features

### 1. Capital-Weighted Yield
Members earn yield proportional to their capital contribution:
```
memberYield = (totalYield × memberCapital) / totalCapitalInGroup
```

### 2. Progressive Protocol Fees
- First 40% of cycles: 0% fee
- Linear increase to 10% by final cycle
- Formula: `fee = (cyclesAfter40% × 10%) / remainingCycles`

### 3. No Catch-up Contributions
- Members can only contribute in current cycle
- Ensures fair time-based participation
- Prevents gaming of yield distribution

### 4. Continuous Claiming
- Members accumulate yield over multiple cycles
- Claim anytime (no cycle restrictions)
- Unclaimed yield remains in vault earning more yield

### 5. Emergency Withdrawals
- 3% penalty before pool end
- No penalty after pool ends
- Penalty benefits remaining members

## Security Features

### Reentrancy Protection
- `nonReentrant` modifier on all state-changing functions
- CEI pattern (Checks-Effects-Interactions)

### Overflow Protection
- Libraries include overflow checks
- Safe casting for packed storage
- Solidity 0.8.18 built-in overflow protection

### Access Control
- Admin-only sensitive operations
- Member-only contribution/claim functions
- Public yield distribution (incentivized)

### Pausability
- Emergency stop mechanism
- Admin-controlled pause/unpause

## Usage Guide

### For Group Admins

#### 1. Deploy Contract
```solidity
constructor(
    address _asset,         // USDC address
    uint256 _amount,        // 50 USDC (50000000)
    uint256 _cycleDuration, // 1 week (604800 seconds)
    uint256 _totalCycles,   // 12 cycles
    address _admin,         // Admin address
    address _vault          // MetaMorpho vault address
)
```

#### 2. Add Members
```solidity
joinGroup(memberAddress); // Before pool starts
```

#### 3. Start Group
```solidity
startGroup(); // After all members joined
```

#### 4. Manage Fees
```solidity
changeProtocolFeeRecipient(newRecipient);
withdrawProtocolFees(); // Collect accumulated fees
```

### For Members

#### 1. Contribute Each Cycle
```solidity
contribute(); // Once per cycle, for current cycle only
```

#### 2. Monitor Yield
```solidity
getMemberInfo(myAddress); // Check pendingYield
```

#### 3. Claim Yield
```solidity
claimYield(); // Claim accumulated yield anytime
```

#### 4. Emergency Exit
```solidity
emergencyWithdraw(); // 3% penalty if pool not ended
```

### For Anyone (Public Good)

#### Distribute Yield
```solidity
// Single cycle
distributeYieldForCycle(cycleNumber);

// Batch (more efficient)
batchDistributeYield([1, 2, 3, 4, 5]);
```

## Gas Cost Estimates

| Operation | Gas Cost | Optimization |
|-----------|----------|--------------|
| Join Group | ~50,000 | Packed storage |
| Contribute | ~80,000 | Direct vault deposit |
| Distribute (10 members) | ~150,000 | Library + unchecked |
| Batch Distribute (5 cycles) | ~500,000 | vs 750,000 individual |
| Claim Yield | ~60,000 | Single vault withdrawal |

## Example Flow

### 12-Week Group, 5 Members, 50 USDC/week

#### Week 1
- All 5 members contribute 50 USDC
- totalCapital = 250 USDC
- Vault generates 5 USDC yield

#### Week 2
- Distribute Week 1 yield (5 USDC ÷ 5 = 1 USDC each)
- All contribute 50 USDC
- totalCapital = 500 USDC
- Vault generates 12 USDC yield

#### Week 3
- Distribute Week 2 yield (12 USDC ÷ 5 = 2.4 USDC each)
- Member A claims 3.4 USDC (1 + 2.4)
- Members B-E accumulate

#### Week 12
- Protocol fee = 0% (still in first 40%)
- Final distribution
- All members withdraw capital + yield

## Comparison: V1 vs V2

| Feature | V1 | V2 |
|---------|----|----|
| Yield Model | Merkle FIFO | Capital-weighted |
| Storage | 5 slots/member | 2 slots/member |
| Catch-up | ✗ | ✗ |
| Batch Ops | ✗ | ✓ |
| Libraries | ✗ | ✓ |
| Gas Efficiency | Baseline | 40-60% better |

## Testing Checklist

- [ ] Member join/leave flows
- [ ] Contribution timing enforcement
- [ ] Yield distribution accuracy
- [ ] Protocol fee progression
- [ ] Emergency withdrawal penalties
- [ ] Batch operations
- [ ] Reentrancy attacks
- [ ] Overflow scenarios
- [ ] Access control
- [ ] Pausability

## Deployment Checklist

- [ ] Audit all library functions
- [ ] Verify vault compatibility (ERC4626)
- [ ] Set correct asset decimals
- [ ] Configure cycle parameters
- [ ] Test on testnet
- [ ] Monitor gas costs
- [ ] Set protocol fee recipient
- [ ] Deploy with multisig admin

## Integration Guide

### Frontend Integration
```typescript
// Get member info
const { capitalInGroup, pendingYield, lastContributedCycle, isActive } 
    = await zybraGroup.getMemberInfo(userAddress);

// Get pool status
const { started, ended, currentCycle, totalMembers, totalCapital, totalYield } 
    = await zybraGroup.getGroupStatus();

// Contribute (ensure approval first)
await usdcContract.approve(zybraGroupAddress, contributionAmount);
await zybraGroup.contribute();

// Claim yield
await zybraGroup.claimYield();

// Distribute yield (anyone can call)
await zybraGroup.batchDistributeYield([1, 2, 3]);
```

### Event Monitoring
```typescript
// Listen for contributions
zybraGroup.on("Contributed", (member, amount, cycle, totalCapital) => {
    console.log(`${member} contributed ${amount} in cycle ${cycle}`);
});

// Listen for yield distribution
zybraGroup.on("YieldDistributed", (cycle, totalYield, eligibleCapital) => {
    console.log(`Cycle ${cycle}: ${totalYield} yield distributed`);
});

// Listen for claims
zybraGroup.on("YieldClaimed", (member, amount) => {
    console.log(`${member} claimed ${amount}`);
});
```

## Advanced Considerations

### EIP-7702 Wallet Integration
- Batch approve + contribute in single transaction
- Lower user friction
- Gas savings from combined operations

### Yield Optimization Strategies
- Auto-compound option (future)
- Yield swap for governance tokens
- Multi-vault support

### Scalability
- Current: 50 members max (gas limit)
- Future: Merkle-based claiming for larger pools
- Layer 2 deployment for higher throughput

## License
MIT
