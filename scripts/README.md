# Test Scripts

This directory contains scripts for running mainnet fork integration tests.

## Quick Start

### Windows (PowerShell)
```powershell
# From project root
.\test-fork.ps1
```

### Linux/Mac
```bash
# From project root
chmod +x test-fork.sh
./test-fork.sh
```

## Available Scripts

### 1. `test-fork.ps1` / `test-fork.sh` (Recommended)
**Location:** Project root  
**Purpose:** Quick test runner using forge's built-in forking

Simple, fast, and reliable. Uses forge's internal fork mechanism.

### 2. `run-anvil-fork-test.ps1` / `run-anvil-fork-test.sh`
**Location:** `scripts/`  
**Purpose:** Advanced test runner with separate Anvil process

Features:
- Starts Anvil in background
- Configurable port and settings
- Captures Anvil logs
- Automatic cleanup on exit

Use when you need:
- Custom Anvil configuration
- Separate process control
- Anvil log inspection
- Multiple parallel test runs

## Configuration

### Environment Variables
Create a `.env` file in project root:
```bash
MAINNET_RPC_URL=https://eth-mainnet.g.alchemy.com/v2/YOUR_API_KEY
```

### Test Parameters
Edit `test/ZybraGroupMainnetFork.t.sol` to modify:
- `CONTRIBUTION_AMOUNT`: Default 100 USDC (100e6)
- `CYCLE_LENGTH`: Default 1 week
- `MEMBER_COUNT`: Default 5 members
- `ETH_TO_SWAP`: Default 1 ETH per member

## Test Scenarios

### Run Specific Test
```bash
forge test --match-test testCompleteMainnetFlow --fork-url $MAINNET_RPC_URL -vvv
```

### Run All Fork Tests
```bash
forge test --match-contract ZybraGroupMainnetForkTest --fork-url $MAINNET_RPC_URL -vv
```

### With Gas Report
```bash
forge test --match-contract ZybraGroupMainnetForkTest --fork-url $MAINNET_RPC_URL --gas-report
```

## Troubleshooting

### Script won't run
**Windows:** Ensure PowerShell execution policy allows scripts
```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

**Linux/Mac:** Make script executable
```bash
chmod +x test-fork.sh
```

### RPC errors
- Verify `.env` file exists
- Check `MAINNET_RPC_URL` is valid
- Ensure RPC provider has sufficient credits
- Try using Alchemy's free tier

### Anvil won't start
- Check if port 8545 is available
- Kill existing Anvil processes
- Check `anvil.log` for errors
- Verify Anvil is installed: `anvil --version`

## Additional Resources

- See `docs/MAINNET_FORK_TESTING.md` for comprehensive guide
- See `docs/PAYOUT_ORDER_GUIDE.md` for Merkle tree documentation
- See `test/ZybraGroupMainnetFork.t.sol` for test implementation

## Examples

### Basic run
```bash
# Windows
.\test-fork.ps1

# Linux/Mac  
./test-fork.sh
```

### With custom RPC
```bash
# Windows
$env:MAINNET_RPC_URL="https://your-rpc-url.com"
.\test-fork.ps1

# Linux/Mac
MAINNET_RPC_URL=https://your-rpc-url.com ./test-fork.sh
```

### Using Anvil script
```bash
# Windows
.\scripts\run-anvil-fork-test.ps1

# Linux/Mac
./scripts/run-anvil-fork-test.sh
```

### Debug mode
```bash
forge test \
    --match-test testCompleteMainnetFlow \
    --fork-url $MAINNET_RPC_URL \
    -vvvv \
    --debug
```
