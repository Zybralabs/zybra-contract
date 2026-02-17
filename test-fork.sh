#!/bin/bash
# Quick test script for running mainnet fork tests
# This uses Forge's built-in forking (no need to start Anvil separately)
# Usage: ./test-fork.sh

echo ""
echo "============================================"
echo "  Mainnet Fork Tests (Forge Built-in)"
echo "============================================"
echo ""

# Check for .env file
if [ ! -f .env ]; then
    echo "Warning: .env file not found. Using default RPC URL"
    echo "Create .env with: MAINNET_RPC_URL=https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY"
    echo ""
fi

# Load .env if exists
if [ -f .env ]; then
    source .env
    echo "[OK] Loaded RPC URL from .env"
    echo ""
fi

echo "Running tests with Anvil default accounts:"
echo "  Account 0 (Admin):   0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
echo "  Account 1 (Member1): 0x70997970C51812dc3A010C7d01b50e0d17dc79C8"
echo "  Account 2 (Member2): 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC"
echo "  Account 3 (Member3): 0x90F79bf6EB2c4f870365E785982E1f101E93b906"
echo "  Account 4 (Member4): 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65"
echo "  Account 5 (Member5): 0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc"
echo ""
echo "Each account has 10,000 ETH automatically"
echo ""

# Run specific test
echo "Running testCompleteMainnetFlow..."
forge test \
    --match-contract ZybraGroupMainnetForkTest \
    --match-test testCompleteMainnetFlow \
    --fork-url ${MAINNET_RPC_URL:-https://eth-mainnet.g.alchemy.com/v2/demo} \
    -vvvv \
    --gas-report

echo ""
if [ $? -eq 0 ]; then
    echo "============================================"
    echo "  All Tests Passed!"
    echo "============================================"
else
    echo "============================================"
    echo "  Tests Failed!"
    echo "============================================"
fi
echo ""
