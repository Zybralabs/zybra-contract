# Quick test script for running mainnet fork tests
# This connects to a running Anvil fork instance
# Usage:
#   1. Start Anvil: anvil --fork-url https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY
#   2. Run tests: .\test-fork.ps1

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Mainnet Fork Tests (Anvil)" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

Write-Host "IMPORTANT: Make sure Anvil is running!" -ForegroundColor Yellow
Write-Host "  Start Anvil in another terminal with:" -ForegroundColor Yellow
Write-Host "  anvil --fork-url https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY" -ForegroundColor Gray
Write-Host ""

Write-Host "Running tests with Anvil default accounts:" -ForegroundColor Yellow
Write-Host "  Account 0 (Admin):   0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266" -ForegroundColor Gray
Write-Host "  Account 1 (Member1): 0x70997970C51812dc3A010C7d01b50e0d17dc79C8" -ForegroundColor Gray
Write-Host "  Account 2 (Member2): 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC" -ForegroundColor Gray
Write-Host "  Account 3 (Member3): 0x90F79bf6EB2c4f870365E785982E1f101E93b906" -ForegroundColor Gray
Write-Host "  Account 4 (Member4): 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65" -ForegroundColor Gray
Write-Host "  Account 5 (Member5): 0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc" -ForegroundColor Gray
Write-Host ""
Write-Host "Each account has 10,000 ETH automatically" -ForegroundColor Gray
Write-Host ""

# Run specific test
Write-Host "Running testCompleteMainnetFlow..." -ForegroundColor Cyan
forge test `
    --match-contract ZybraGroupMainnetForkTest `
    --match-test testCompleteMainnetFlow `
    --fork-url http://127.0.0.1:8545 `
    -vv

Write-Host ""
if ($LASTEXITCODE -eq 0) {
    Write-Host "============================================" -ForegroundColor Green
    Write-Host "  All Tests Passed!" -ForegroundColor Green
    Write-Host "============================================" -ForegroundColor Green
} else {
    Write-Host "============================================" -ForegroundColor Red
    Write-Host "  Tests Failed!" -ForegroundColor Red
    Write-Host "============================================" -ForegroundColor Red
}
Write-Host ""
