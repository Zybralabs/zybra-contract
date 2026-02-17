# PowerShell script to run mainnet fork tests with Anvil
# This script starts Anvil in the background, runs tests, and cleans up

$ErrorActionPreference = "Stop"

Write-Host "================================================" -ForegroundColor Cyan
Write-Host "Zybra Group Mainnet Fork Integration Test" -ForegroundColor Cyan
Write-Host "================================================" -ForegroundColor Cyan
Write-Host ""

# Check if .env file exists
if (-not (Test-Path .env)) {
    Write-Host "Error: .env file not found!" -ForegroundColor Red
    Write-Host "Please create a .env file with MAINNET_RPC_URL"
    Write-Host "Example: MAINNET_RPC_URL=https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY"
    exit 1
}

# Load environment variables from .env file
Get-Content .env | ForEach-Object {
    if ($_ -match '^\s*([^#][^=]*?)\s*=\s*(.*?)\s*$') {
        $name = $matches[1]
        $value = $matches[2]
        Set-Item -Path "env:$name" -Value $value
    }
}

if (-not $env:MAINNET_RPC_URL) {
    Write-Host "Error: MAINNET_RPC_URL not set in .env file" -ForegroundColor Red
    exit 1
}

Write-Host "✓ Environment variables loaded" -ForegroundColor Green
$rpcPreview = $env:MAINNET_RPC_URL.Substring(0, [Math]::Min(30, $env:MAINNET_RPC_URL.Length))
Write-Host "RPC URL: $rpcPreview..." -ForegroundColor Gray
Write-Host ""

# Start Anvil in the background with mainnet fork
Write-Host "Starting Anvil with mainnet fork..." -ForegroundColor Yellow
$anvilPort = 8545

$anvilArgs = @(
    "--fork-url", $env:MAINNET_RPC_URL,
    "--port", $anvilPort,
    "--chain-id", "1",
    "--block-time", "12",
    "--gas-limit", "30000000",
    "--code-size-limit", "30000",
    "--accounts", "10",
    "--balance", "10000"
)

# Start Anvil process
$anvilProcess = Start-Process -FilePath "anvil" -ArgumentList $anvilArgs -PassThru -RedirectStandardOutput "anvil.log" -RedirectStandardError "anvil_error.log" -NoNewWindow

Write-Host "✓ Anvil started (PID: $($anvilProcess.Id))" -ForegroundColor Green
Write-Host "  Listening on http://localhost:$anvilPort" -ForegroundColor Gray
Write-Host "  Logs: anvil.log" -ForegroundColor Gray
Write-Host ""

# Wait for Anvil to be ready
Write-Host "Waiting for Anvil to be ready..." -ForegroundColor Yellow
Start-Sleep -Seconds 5

# Check if Anvil is still running
if ($anvilProcess.HasExited) {
    Write-Host "Error: Anvil failed to start. Check anvil.log and anvil_error.log for details." -ForegroundColor Red
    Get-Content anvil_error.log
    exit 1
}

Write-Host "✓ Anvil is ready" -ForegroundColor Green
Write-Host ""

# Function to cleanup
function Cleanup {
    Write-Host ""
    Write-Host "Cleaning up..." -ForegroundColor Yellow
    if ($anvilProcess -and -not $anvilProcess.HasExited) {
        Write-Host "Stopping Anvil (PID: $($anvilProcess.Id))..." -ForegroundColor Yellow
        Stop-Process -Id $anvilProcess.Id -Force -ErrorAction SilentlyContinue
        Write-Host "✓ Anvil stopped" -ForegroundColor Green
    }
}

# Set cleanup to run on exit
try {
    # Run the tests
    Write-Host "================================================" -ForegroundColor Cyan
    Write-Host "Running Mainnet Fork Integration Tests" -ForegroundColor Cyan
    Write-Host "================================================" -ForegroundColor Cyan
    Write-Host ""

    # Set the local Anvil RPC for forge to use
    $env:MAINNET_RPC_URL = "http://localhost:$anvilPort"

    # Run forge test with verbosity
    $forgeArgs = @(
        "test",
        "--match-contract", "ZybraGroupMainnetForkTest",
        "--fork-url", "http://localhost:$anvilPort",
        "--fork-block-number", "latest",
        "-vvv"
    )

    & forge $forgeArgs

    $testExitCode = $LASTEXITCODE

    Write-Host ""
    Write-Host "================================================" -ForegroundColor Cyan
    if ($testExitCode -eq 0) {
        Write-Host "✓ All tests passed!" -ForegroundColor Green
    } else {
        Write-Host "✗ Tests failed with exit code: $testExitCode" -ForegroundColor Red
        Write-Host "Check anvil.log for details" -ForegroundColor Yellow
    }
    Write-Host "================================================" -ForegroundColor Cyan

    exit $testExitCode
}
finally {
    Cleanup
}
