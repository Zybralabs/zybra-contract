# Zybra V2 Local Deployment (Anvil)

Deployed on: January 14, 2026
Network: Local Anvil (Chain ID: 31337)

## Contract Addresses

| Contract | Address |
|----------|---------|
| **MockUSDC** | `0x5FbDB2315678afecb367f032d93F642f64180aa3` |
| **MockYieldVault** (Mock Morpho Vault) | `0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512` |
| **ZybraGroupFactoryV2** | `0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0` |
| **ZybraGroupV2** (Sample Group) | `0x75537828f2ce51be7289709686A69CbFDbB714F1` |

## Deployer
- Address: `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266`
- USDC Balance: 100,000 USDC

## Group Parameters
- Contribution Amount: 100 USDC
- Cycle Duration: 7 days
- Total Cycles: 4
- Admin: Deployer address
- Vault: MockYieldVault

## Vault Configuration
- Vault funded with: 1,000,000 USDC (for yield generation)
- Type: ERC4626-compliant Mock Vault

## How to Interact

### Using Cast (CLI)
```bash
# Check USDC balance
cast call 0x5FbDB2315678afecb367f032d93F642f64180aa3 "balanceOf(address)" 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 --rpc-url http://127.0.0.1:8545

# Approve USDC for the group
cast send 0x5FbDB2315678afecb367f032d93F642f64180aa3 "approve(address,uint256)" 0x75537828f2ce51be7289709686A69CbFDbB714F1 1000000000000 --rpc-url http://127.0.0.1:8545 --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

# Join the group (as admin adding a user)
cast send 0x75537828f2ce51be7289709686A69CbFDbB714F1 "joinGroup(address)" 0x70997970C51812dc3A010C7d01b50e0d17dc79C8 --rpc-url http://127.0.0.1:8545 --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

# Start the group
cast send 0x75537828f2ce51be7289709686A69CbFDbB714F1 "startGroup()" --rpc-url http://127.0.0.1:8545 --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

# Contribute
cast send 0x75537828f2ce51be7289709686A69CbFDbB714F1 "contribute(address)" 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 --rpc-url http://127.0.0.1:8545 --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
```

### Available Anvil Accounts

| # | Address | Private Key |
|---|---------|-------------|
| 0 | 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 | 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 |
| 1 | 0x70997970C51812dc3A010C7d01b50e0d17dc79C8 | 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d |
| 2 | 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC | 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a |
| 3 | 0x90F79bf6EB2c4f870365E785982E1f101E93b906 | 0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6 |

## Redeploy Command
```bash
cd e:\zybra-sms\contracts
$env:Path = "$env:USERPROFILE\.foundry\bin;$env:Path"

# Start Anvil (in separate terminal)
anvil --host 127.0.0.1 --port 8545

# Deploy
forge script script/DeployZybraV2.s.sol --rpc-url http://127.0.0.1:8545 --broadcast --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 -vvv
```
