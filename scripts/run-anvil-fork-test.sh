#!/bin/bash

# Script to run mainnet fork tests with Anvil
# This script starts Anvil in the background, runs tests, and cleans up

set -e

echo "================================================"
echo "Zybra Group Mainnet Fork Integration Test"
echo "================================================"
echo ""

# Check if .env file exists
if [ ! -f .env ]; then
    echo "Error: .env file not found!"
    echo "Please create a .env file with MAINNET_RPC_URL"
    echo "Example: MAINNET_RPC_URL=https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY"
    exit 1
fi

# Load environment variables
source .env

if [ -z "$MAINNET_RPC_URL" ]; then
    echo "Error: MAINNET_RPC_URL not set in .env file"
    exit 1
fi

echo "✓ Environment variables loaded"
echo "RPC URL: ${MAINNET_RPC_URL:0:30}..."
echo ""

# Start Anvil in the background with mainnet fork
echo "Starting Anvil with mainnet fork..."
ANVIL_PORT=8545
anvil --fork-url $MAINNET_RPC_URL \
      --port $ANVIL_PORT \
      --chain-id 1 \
      --block-time 12 \
      --gas-limit 30000000 \
      --code-size-limit 30000 \
      --accounts 10 \
      --balance 10000 \
      > anvil.log 2>&1 &

ANVIL_PID=$!
echo "✓ Anvil started (PID: $ANVIL_PID)"
echo "  Listening on http://localhost:$ANVIL_PORT"
echo "  Logs: anvil.log"
echo ""

# Wait for Anvil to be ready
echo "Waiting for Anvil to be ready..."
sleep 3

# Check if Anvil is running
if ! kill -0 $ANVIL_PID 2>/dev/null; then
    echo "Error: Anvil failed to start. Check anvil.log for details."
    exit 1
fi

echo "✓ Anvil is ready"
echo ""

# Function to cleanup on exit
cleanup() {
    echo ""
    echo "Cleaning up..."
    if [ ! -z "$ANVIL_PID" ]; then
        echo "Stopping Anvil (PID: $ANVIL_PID)..."
        kill $ANVIL_PID 2>/dev/null || true
        wait $ANVIL_PID 2>/dev/null || true
        echo "✓ Anvil stopped"
    fi
}

# Set trap to cleanup on exit
trap cleanup EXIT INT TERM

# Run the tests
echo "================================================"
echo "Running Mainnet Fork Integration Tests"
echo "================================================"
echo ""

# Export the local Anvil RPC for forge to use
export MAINNET_RPC_URL="http://localhost:$ANVIL_PORT"

# Run forge test with verbosity
forge test \
    --match-contract ZybraGroupMainnetForkTest \
    --fork-url http://localhost:$ANVIL_PORT \
    --fork-block-number latest \
    -vvv

TEST_EXIT_CODE=$?

echo ""
echo "================================================"
if [ $TEST_EXIT_CODE -eq 0 ]; then
    echo "✓ All tests passed!"
else
    echo "✗ Tests failed with exit code: $TEST_EXIT_CODE"
    echo "Check anvil.log for details"
fi
echo "================================================"

exit $TEST_EXIT_CODE
