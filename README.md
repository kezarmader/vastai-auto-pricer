# Vast.ai Auto-Pricer

Automatically monitor and adjust pricing for your Vast.ai hosted machines based on real-time market demand.

## Features

- **Smart Demand Analysis**: Monitors market utilization for similar GPU offerings
- **Dynamic Pricing**: Automatically increases prices during high demand, decreases during low demand
- **Safety Controls**: Configurable min/max price limits to protect your earnings
- **Test Mode**: Safely test the logic without making actual price changes
- **Background Operation**: Runs continuously in the background
- **Detailed Logging**: Tracks all decisions and price changes

## Prerequisites

- Vast.ai CLI installed and configured (`vastai` command available)
- PowerShell 5.1 or higher (Windows)
- Active Vast.ai host account with listed machines

## Installation

1. Clone this repository:
```bash
git clone <your-repo-url>
cd autoPricer
```

2. Ensure Vast.ai CLI is set up:
```bash
vastai set api-key YOUR_API_KEY
```

## Usage

### Test Mode (Recommended First)
Run without making actual price changes:
```powershell
.\monitor_vastai_pricing.ps1 -TestMode -IntervalMinutes 1
```

### Production Mode
Run with actual price adjustments:
```powershell
.\monitor_vastai_pricing.ps1
```

### Background Mode
Run continuously in background:
```powershell
Start-Process powershell -ArgumentList "-File .\monitor_vastai_pricing.ps1" -WindowStyle Hidden
```

### Custom Configuration
```powershell
.\monitor_vastai_pricing.ps1 `
    -BasePrice 0.40 `
    -MaxPrice 3.00 `
    -IntervalMinutes 15 `
    -PriceStepPercent 15 `
    -HighDemandThreshold 85 `
    -LowDemandThreshold 25
```

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `IntervalMinutes` | 10 | How often to check and adjust prices |
| `BasePrice` | 0.50 | Minimum price per GPU per hour |
| `MaxPrice` | 2.00 | Maximum price per GPU per hour |
| `PriceStepPercent` | 10 | Percentage to adjust price each time |
| `HighDemandThreshold` | 80 | Market utilization % to trigger price increase |
| `LowDemandThreshold` | 30 | Market utilization % to trigger price decrease |
| `LogFile` | vastai_pricing_log.txt | Path to log file |
| `TestMode` | false | Run without making actual changes |

## How It Works

1. **Market Analysis**: Searches for similar GPU offers on Vast.ai marketplace
2. **Demand Calculation**: Calculates percentage of rented vs available machines
3. **Price Decision**:
   - High demand (>80%): Increase price by 10%
   - Low demand (<30%): Decrease price by 10%
   - Medium demand: Hold current price
4. **Safety Check**: Ensures new price stays within min/max bounds
5. **Update**: Applies new price using `vastai set min-bid` command

## Stopping the Script

If running in foreground, press `Ctrl+C`.

If running in background:
```powershell
Get-Process powershell | Where-Object {$_.CommandLine -match "monitor_vastai_pricing"} | Stop-Process
```

## Log Files

All actions are logged to `vastai_pricing_log.txt` with timestamps:
- Market demand percentages
- Price decisions and reasons
- Successful/failed price updates
- Error messages

## License

MIT

## Contributing

Pull requests welcome! Please test thoroughly in test mode first.
