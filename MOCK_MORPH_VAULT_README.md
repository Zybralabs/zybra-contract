# MockMorphVault - Time-Based Reward Vault

## Overview

`MockMorphVault` is a demo ERC4626-compliant vault that generates rewards based on the time users have been deposited in the vault. It's designed to be compatible with Morpho V2 architecture patterns while being simplified for testing and demonstration purposes.

## Key Features

- ✅ **ERC4626 Compliant**: Full compatibility with the tokenized vault standard
- ✅ **Time-Based Rewards**: Users earn rewards proportional to their deposit duration
- ✅ **Per-User Tracking**: Individual reward accounting for each depositor
- ✅ **Configurable APY**: Owner can adjust reward rates
- ✅ **Morpho V2 Compatible**: Follows Morpho vault architecture patterns
- ✅ **Mainnet Ready**: Safe for testnet and mainnet deployment

## Architecture

### Reward Mechanism

The vault generates rewards using a time-based formula:

```
Rewards = (User Assets × Reward Rate × Time Elapsed) / (WAD × Seconds Per Year)
```

Where:
- `User Assets`: Current value of user's shares in the vault
- `Reward Rate`: Annual percentage yield in WAD (e.g., 0.1e18 = 10%)
- `Time Elapsed`: Seconds since last reward update
- `WAD`: 1e18 (standard fixed-point precision)

### User Info Structure

Each user has the following tracked data:

```solidity
struct UserInfo {
    uint256 depositTimestamp;  // When user first deposited
    uint256 lastRewardUpdate;  // Last time rewards were calculated
    uint256 pendingRewards;    // Rewards accrued but not claimed
    uint256 totalDeposited;    // Total assets ever deposited
    uint256 totalWithdrawn;    // Total assets ever withdrawn
}
```

### Reward Accrual Flow

1. **On Deposit**: User info is initialized/updated, rewards accrue from this point
2. **Over Time**: Rewards continuously accrue based on time elapsed
3. **On Interaction**: Any balance-changing operation accrues pending rewards
4. **On Claim**: User receives pending rewards, counter resets

## Contract Interface

### Core Functions

#### Deposit & Withdrawal

```solidity
// Deposit assets and receive shares
function deposit(uint256 assets, address receiver) returns (uint256 shares)

// Mint specific amount of shares
function mint(uint256 shares, address receiver) returns (uint256 assets)

// Withdraw assets by burning shares
function withdraw(uint256 assets, address receiver, address owner) returns (uint256 shares)

// Redeem shares for assets
function redeem(uint256 shares, address receiver, address owner) returns (uint256 assets)
```

#### Reward Functions

```solidity
// View pending rewards for a user
function pendingRewards(address user) returns (uint256)

// Claim all pending rewards
function claimRewards() returns (uint256 rewards)

// Get user's total earnings (claimed + pending)
function getTotalEarnings(address user) returns (uint256)

// Estimate annual yield for a user
function estimateAnnualYield(address user) returns (uint256)
```

#### Admin Functions

```solidity
// Set the annual reward rate (only owner)
function setRewardRate(uint256 newRate)

// Fund vault with reward tokens (only owner)
function fundRewards(uint256 amount)

// Transfer ownership (only owner)
function transferOwnership(address newOwner)
```

#### View Functions

```solidity
// Get complete user information
function getUserInfo(address user) returns (UserInfo memory)

// Get user's time in vault (seconds)
function getTimeInVault(address user) returns (uint256)

// Get current APY
function currentAPY() returns (uint256)

// Check if vault has sufficient rewards
function isSufficientlyFunded() returns (bool)
```

## Usage Examples

### Basic Deposit and Reward Claiming

```solidity
// User approves vault
IERC20(asset).approve(address(vault), 1000e6);

// User deposits 1000 USDC
vault.deposit(1000e6, msg.sender);

// Wait some time...
// (User earns rewards based on time)

// Check pending rewards
uint256 pending = vault.pendingRewards(msg.sender);

// Claim rewards
uint256 claimed = vault.claimRewards();
```

### Multiple Deposits Over Time

```solidity
// First deposit at day 0
vault.deposit(500e6, alice);

// Second deposit at day 30
// (30 days later)
vault.deposit(500e6, alice);

// Check rewards at day 60
// Alice will have:
// - 500 USDC earning for 60 days
// - 500 USDC earning for 30 days
uint256 rewards = vault.pendingRewards(alice);
```

### Checking User Statistics

```solidity
// Get user info
MockMorphVault.UserInfo memory info = vault.getUserInfo(alice);
console.log("Deposit timestamp:", info.depositTimestamp);
console.log("Total deposited:", info.totalDeposited);

// Get time in vault
uint256 timeInVault = vault.getTimeInVault(alice);
console.log("Days in vault:", timeInVault / 1 days);

// Get estimated annual yield
uint256 annualYield = vault.estimateAnnualYield(alice);
console.log("Expected annual yield:", annualYield);
```

## Deployment

### Option 1: Deploy with Existing Asset Token

```bash
# Set environment variables
export PRIVATE_KEY=<your_private_key>
export ASSET_TOKEN=<usdc_address>

# Deploy
forge script script/DeployMockMorphVault.s.sol:DeployMockMorphVault \
  --rpc-url $SEPOLIA_RPC_URL \
  --broadcast \
  --verify
```

### Option 2: Deploy with Mock Asset (Testing)

```bash
# Set environment variables
export PRIVATE_KEY=<your_private_key>

# Deploy (will create mock USDC too)
forge script script/DeployMockMorphVault.s.sol:DeployMockMorphVaultWithMockAsset \
  --rpc-url $SEPOLIA_RPC_URL \
  --broadcast \
  --verify
```

### Option 3: Sepolia Deployment

```bash
# Set environment variables
export PRIVATE_KEY=<your_private_key>

# Deploy to Sepolia
forge script script/DeployMockMorphVault.s.sol:DeployMockMorphVaultSepolia \
  --rpc-url $SEPOLIA_RPC_URL \
  --broadcast \
  --verify
```

## Testing

Run the comprehensive test suite:

```bash
# Run all tests
forge test --match-contract MockMorphVaultTest -vv

# Run specific test
forge test --match-test test_RewardsAccrueOverTime -vvv

# Run with gas reporting
forge test --match-contract MockMorphVaultTest --gas-report

# Run fuzz tests
forge test --match-test testFuzz -vv
```

### Test Coverage

The test suite includes:

- ✅ Basic deposit/withdrawal functionality
- ✅ Time-based reward accrual
- ✅ Multiple user scenarios
- ✅ Early depositor advantages
- ✅ Reward claiming
- ✅ Rate adjustments
- ✅ Edge cases (zero deposits, multiple deposits)
- ✅ User info tracking
- ✅ Ownership controls
- ✅ Fuzz testing
- ✅ Complex integration scenarios

## Security Considerations

### Morpho V2 Compatibility

This mock vault follows key Morpho V2 patterns:

1. **Virtual Shares**: Uses virtual shares for inflation attack protection
2. **Decimal Offset**: Protects against share manipulation
3. **Safe Math**: Uses OpenZeppelin's Math library for safe calculations
4. **ERC4626 Standard**: Full compliance with tokenized vault standard

### Key Differences from Production Morpho Vaults

⚠️ **This is a DEMO vault**. Key simplifications:

1. **No Adapter System**: Real Morpho vaults use adapters for capital allocation
2. **No Timelocks**: Admin functions execute immediately (production uses timelocks)
3. **Simplified Fee Model**: Single reward rate instead of performance/management fees
4. **No Gates**: No receive/send gates for permissioned access
5. **No Force Deallocate**: No emergency withdrawal mechanisms
6. **Manual Reward Funding**: Requires owner to fund rewards (vs. yield from protocols)

### Production Deployment Checklist

If deploying to mainnet:

- [ ] Audit the contract (recommend professional audit)
- [ ] Ensure sufficient reward funding
- [ ] Set appropriate reward rate (not too high)
- [ ] Test extensively on testnet first
- [ ] Monitor vault funding levels
- [ ] Set up monitoring for `isSufficientlyFunded()`
- [ ] Consider implementing emergency pause mechanism
- [ ] Add additional access controls if needed

## Configuration

### Default Parameters

```solidity
// Reward rate: 10% APY
rewardRate = 0.1e18

// Maximum allowed rate: 50% APY
MAX_REWARD_RATE = 0.5e18

// Virtual shares for inflation protection
VIRTUAL_SHARES = 1e6

// Seconds per year
SECONDS_PER_YEAR = 365 days
```

### Adjusting Reward Rate

```solidity
// Owner can update rate
vault.setRewardRate(0.15e18); // Set to 15% APY

// Maximum is 50%
vault.setRewardRate(0.5e18);  // Max allowed

// Will revert if too high
vault.setRewardRate(0.6e18);  // ❌ Reverts
```

## Events

The vault emits the following events:

```solidity
// User joins vault
event UserJoined(address indexed user, uint256 assets, uint256 shares, uint256 timestamp)

// User exits vault
event UserExited(address indexed user, uint256 assets, uint256 shares, uint256 rewards)

// Rewards accrued for user
event RewardAccrued(address indexed user, uint256 rewardAmount, uint256 timeElapsed)

// Reward rate updated
event RewardRateUpdated(uint256 oldRate, uint256 newRate)

// Total rewards distributed
event TotalRewardsDistributed(uint256 totalRewards)
```

## Gas Optimization

The vault is optimized for gas efficiency:

- Rewards calculated only when needed (lazy evaluation)
- Single storage update per user interaction
- Efficient mapping-based storage
- No unnecessary loops or iterations

## Comparison with Morpho V2

| Feature | MockMorphVault | Morpho VaultV2 |
|---------|----------------|----------------|
| ERC4626 Compliance | ✅ | ✅ |
| Time-based rewards | ✅ | ❌ (yield-based) |
| Adapters | ❌ | ✅ |
| Timelocks | ❌ | ✅ |
| Performance Fees | ❌ | ✅ |
| Management Fees | ❌ | ✅ |
| Gates | ❌ | ✅ |
| Caps | ❌ | ✅ |
| Force Deallocate | ❌ | ✅ |
| Allocators | ❌ | ✅ |
| Curators | ❌ | ✅ |
| Virtual Shares | ✅ | ✅ |

## FAQ

**Q: Can I use this in production?**
A: This is a demo/testing vault. For production, use official Morpho vaults or conduct a professional audit.

**Q: How are rewards funded?**
A: The owner must fund the vault using `fundRewards()`. The vault tracks available rewards separately from user deposits.

**Q: What happens if rewards run out?**
A: Users can check `isSufficientlyFunded()`. If insufficient, `claimRewards()` will only distribute available rewards.

**Q: Can users lose their principal?**
A: No. User deposits are separate from rewards. Even if rewards run out, users can always withdraw their deposits.

**Q: How accurate are the reward calculations?**
A: Very accurate. Uses high-precision fixed-point math (18 decimals) for calculations.

**Q: Can the owner steal user funds?**
A: No. The owner can only set reward rates and fund rewards. User deposits are protected.

**Q: Why time-based instead of yield-based?**
A: For demo purposes. Real Morpho vaults earn yield from lending protocols. This vault simulates rewards for testing.

**Q: Is this compatible with Morpho V2 architecture?**
A: Yes, it follows key architectural patterns (ERC4626, virtual shares, safe math) but is simplified for demo purposes.

## Support

For issues or questions:
- GitHub: [your-repo/issues]
- Documentation: [Morpho V2 Docs](https://github.com/morpho-org/vault-v2)
- Contact: Zybra SMS Team

## License

GPL-2.0-or-later

Copyright (c) 2025 Morpho Association (architecture inspiration)
Copyright (c) 2025 Zybra SMS Team (implementation)
