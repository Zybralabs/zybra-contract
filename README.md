## Foundry

# ZybraGroup Smart Contract

## Overview

ZybraGroup is an enhanced ROSCA (Rotating Savings and Credit Association) smart contract that integrates with Morpho Vault for yield generation and uses Merkle proofs for secure payout verification.

## Features

### Core ROSCA Functionality
- **Group Creation**: Admin creates groups with specified parameters
- **Member Management**: Add/remove members with assigned payout weeks
- **Contributions**: Members contribute fixed amounts each cycle
- **Scheduled Payouts**: Members receive payouts on their assigned weeks

### Morpho Integration
- **Yield Generation**: Group funds are deposited into Morpho vaults to earn yield
- **Automated Deposits**: Admin can deposit collected contributions to Morpho
- **Secure Withdrawals**: Funds withdrawn from Morpho for member payouts

### Merkle Payout System
- **Secure Verification**: Uses Merkle proofs to verify payout eligibility
- **Gas Efficient**: Only store root hash, not entire payout schedule
- **Tamper Proof**: Cryptographic verification prevents unauthorized claims

### Security Features
- **Access Control**: Admin and member-only functions
- **Pause Mechanism**: Emergency pause functionality
- **Input Validation**: Comprehensive validation on all inputs
- **Custom Errors**: Gas-efficient error handling
- **Emergency Withdrawal**: Admin can withdraw funds when paused

## Contract Parameters

```solidity
constructor(
    address _asset,           // ERC20 token address (e.g., USDC)
    uint256 _amount,          // Contribution amount per member
    uint256 _cycleLength,     // Number of weeks in cycle
    address _admin,           // Group administrator
    address _morpho,          // Morpho protocol address
    MarketParams _marketParams, // Morpho market parameters
    bytes32 _payoutMerkleRoot // Merkle root for payout verification
)
```

## Usage Examples

### 1. Deploy Contract
```solidity
MarketParams memory params = MarketParams({
    loanToken: 0xA0b86a33E6476c3E1f5C6Ac0b3dB9C5d5E6F7890, // USDC
    collateralToken: 0x0000000000000000000000000000000000000000,
    oracle: 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6,
    irm: 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC,
    lltv: 800000000000000000 // 80% LTV
});

ZybraGroup group = new ZybraGroup(
    0xA0b86a33E6476c3E1f5C6Ac0b3dB9C5d5E6F7890, // USDC
    100e6,        // 100 USDC contribution
    4,            // 4 week cycle
    msg.sender,   // Admin
    0x96...morphoAddress,
    params,
    merkleRoot
);
```

### 2. Add Members
```solidity
// Admin adds members
group.joinGroup(memberAddress, 2); // Member gets payout on week 2
```

### 3. Member Contribution
```solidity
// Member approves and contributes
IERC20(usdc).approve(address(group), 100e6);
group.contribute(100e6);
```

### 4. Deposit to Morpho
```solidity
// Admin deposits to Morpho vault for yield
group.depositToMorpho(400e6); // Deposit 4 members' contributions
```

### 5. Claim Payout
```solidity
// Member claims payout with Merkle proof
bytes32[] memory proof = [...]; // Generated off-chain
group.redeemReward(2, 105e6, proof); // Week 2, 105 USDC (100 + yield)
```

## Security Audit Summary ✅

### Security Features Implemented
- ✅ **Reentrancy Protection**: Custom errors and proper state management
- ✅ **Access Control**: Admin/member modifiers with proper validation
- ✅ **Input Validation**: Comprehensive validation on all parameters
- ✅ **Overflow Protection**: Solidity 0.8+ built-in overflow checks
- ✅ **Emergency Controls**: Pause mechanism and emergency withdrawal
- ✅ **Gas Optimization**: Custom errors and efficient data structures
- ✅ **Member Limits**: MAX_MEMBERS prevents gas limit issues
- ✅ **Contribution Bounds**: MIN/MAX_CONTRIBUTION prevents abuse

### Issues Fixed
- ✅ **Proper Share Conversion**: Fixed vault share to asset conversion
- ✅ **Week Advancement**: Secured week progression (admin-only)
- ✅ **Market Validation**: Added market existence verification
- ✅ **Error Handling**: Comprehensive custom error system

## Integration with Backend

The smart contract is designed to work with your existing backend:

1. **Group Creation**: Backend calls constructor with Morpho vault address
2. **Member Management**: Backend manages member addition/removal
3. **Merkle Generation**: Backend generates Merkle roots for payout schedules
4. **Monitoring**: Backend monitors contributions and triggers Morpho deposits

## License

MIT License

Foundry consists of:

- **Forge**: Ethereum testing framework (like Truffle, Hardhat and DappTools).
- **Cast**: Swiss army knife for interacting with EVM smart contracts, sending transactions and getting chain data.
- **Anvil**: Local Ethereum node, akin to Ganache, Hardhat Network.
- **Chisel**: Fast, utilitarian, and verbose solidity REPL.

## Documentation

https://book.getfoundry.sh/

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Anvil

```shell
$ anvil
```

### Deploy

```shell
$ forge script script/Counter.s.sol:CounterScript --rpc-url <your_rpc_url> --private-key <your_private_key>
```

### Cast

```shell
$ cast <subcommand>
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```
