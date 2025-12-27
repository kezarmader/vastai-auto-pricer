# Vast.ai Auto-Pricer - PowerShell Wrapper
# This is a simple wrapper that calls the Python auto-pricer with PowerShell-style parameters

param(
    [int]$IntervalMinutes = 10,
    [double]$BasePrice = 0.50,
    [double]$MaxPrice = 2.00,
    [int]$PriceStepPercent = 10,
    [int]$HighDemandThreshold = 80,
    [int]$LowDemandThreshold = 30,
    [switch]$TestMode,
    [string]$TargetGPU = "RTX_5090",
    [int]$TargetNumGPUs = 1,
    [switch]$Help
)

if ($Help) {
    Write-Host "Vast.ai Auto-Pricer (Python-based)" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Usage:" -ForegroundColor Yellow
    Write-Host "  .\monitor_vastai_pricing.ps1 [-IntervalMinutes <int>] [-BasePrice <double>] ..." -ForegroundColor White
    Write-Host ""
    Write-Host "Parameters:" -ForegroundColor Yellow
    Write-Host "  -IntervalMinutes       Minutes between checks (default: 10)" -ForegroundColor White
    Write-Host "  -BasePrice             Minimum price per GPU/hour (default: 0.50)" -ForegroundColor White
    Write-Host "  -MaxPrice              Maximum price per GPU/hour (default: 2.00)" -ForegroundColor White
    Write-Host "  -PriceStepPercent      Price adjustment percentage (default: 10)" -ForegroundColor White
    Write-Host "  -HighDemandThreshold   High demand threshold % (default: 80)" -ForegroundColor White
    Write-Host "  -LowDemandThreshold    Low demand threshold % (default: 30)" -ForegroundColor White
    Write-Host "  -TestMode              Test without making changes (default: false)" -ForegroundColor White
    Write-Host "  -TargetGPU             GPU model to monitor (default: RTX_5090)" -ForegroundColor White
    Write-Host "  -TargetNumGPUs         Number of GPUs to filter (default: 1)" -ForegroundColor White
    Write-Host ""
    Write-Host "Examples:" -ForegroundColor Yellow
    Write-Host "  .\monitor_vastai_pricing.ps1" -ForegroundColor Green
    Write-Host "  .\monitor_vastai_pricing.ps1 -TestMode -IntervalMinutes 1" -ForegroundColor Green
    Write-Host "  .\monitor_vastai_pricing.ps1 -TargetGPU RTX_4090 -TargetNumGPUs 2" -ForegroundColor Green
    exit 0
}

# Build Python command arguments
$pythonArgs = @(
    "vastai_autopricer.py",
    "--interval", $IntervalMinutes,
    "--base-price", $BasePrice,
    "--max-price", $MaxPrice,
    "--price-step", $PriceStepPercent,
    "--high-demand", $HighDemandThreshold,
    "--low-demand", $LowDemandThreshold,
    "--target-gpu", $TargetGPU,
    "--num-gpus", $TargetNumGPUs
)

# Add test mode flag if enabled
if ($TestMode) {
    $pythonArgs += "--test-mode"
}

# Show what we're running
Write-Host "Starting Vast.ai Auto-Pricer (Python version)..." -ForegroundColor Cyan
Write-Host "Command: python $($pythonArgs -join ' ')" -ForegroundColor Gray
Write-Host ""

# Execute the Python script
& python $pythonArgs
