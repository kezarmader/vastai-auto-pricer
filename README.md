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
- **Python 3.7+** (Recommended - cleanest implementation)
- **Linux**: Bash shell with `jq` and `bc` installed (alternative)
- **Windows**: PowerShell 5.1 or higher (alternative)
- Active Vast.ai host account with listed machines
## Installation

1. Clone this repository:
```bash
git clone https://github.com/kezarmader/vastai-auto-pricer.git
cd vastai-auto-pricer
```

2. Ensure Vast.ai CLI is set up:
```bash
vastai set api-key YOUR_API_KEY
```

3. **For Python (Recommended)**: Ensure Python 3.7+ is installed
```bash
python3 --version
```

4. **For Linux bash version**: Make the wrapper executable:
```bash
chmod +x monitor_vastai_pricing.sh
```
## Usage

### Python (Recommended - Works on Linux, Windows, Mac)

#### Test Mode (Recommended First)
```bash
python3 vastai_autopricer.py --test-mode --interval 1
```

#### Production Mode with Default Settings
```bash
python3 vastai_autopricer.py
```

#### Background Mode
```bash
# Linux/Mac
nohup python3 vastai_autopricer.py > /dev/null 2>&1 &

# Windows
start /B python vastai_autopricer.py
```

#### Custom Configuration
```bash
python3 vastai_autopricer.py \
    --target-gpu RTX_5090 \
    --num-gpus 1 \
    --base-price 0.40 \
    --max-price 1.50 \
    --interval 15 \
    --high-demand 85 \
    --low-demand 25
```

#### See All Options
```bash
python3 vastai_autopricer.py --help
```

---

### Linux Bash (Alternative)

#### Test Mode (Recommended First)
Run without making actual price changes:
```bash
./monitor_vastai_pricing.sh 1 0.50 2.00 10 80 30 true RTX_5090 1
# Arguments: interval basePrice maxPrice priceStep% highThreshold lowThreshold testMode targetGPU numGPUs
```

#### Help
See all configuration options:
```bash
./monitor_vastai_pricing.sh --help
```

#### Production Mode
Run with default settings (RTX 5090, 1 GPU):
```bash
./monitor_vastai_pricing.sh
```

#### Background Mode
Run continuously in background:
```bash
nohup ./monitor_vastai_pricing.sh > /dev/null 2>&1 &
# Check if running: ps aux | grep monitor_vastai
# Stop: pkill -f monitor_vastai_pricing.sh
```

#### Custom Configuration Examples
```bash
# Monitor RTX 4090 with 2 GPUs, custom pricing
./monitor_vastai_pricing.sh 15 0.40 3.00 15 85 25 false RTX_4090 2

# Monitor RTX 3090 with 4 GPUs in test mode
./monitor_vastai_pricing.sh 5 0.30 2.50 12 80 30 true RTX_3090 4

# Default 5090 x1 but custom price range
./monitor_vastai_pricing.sh 10 0.60 4.00 10 80 30 false
```

---

### Windows PowerShell (Alternative)

#### Test Mode (Recommended First)
```powershell
.\monitor_vastai_pricing.ps1 -TestMode -IntervalMinutes 1 -TargetGPU "RTX_5090" -TargetNumGPUs 1
```

#### Production Mode
Run with default settings (RTX 5090, 1 GPU):
```powershell
.\monitor_vastai_pricing.ps1
```

#### Background Mode
```powershell
Start-Process powershell -ArgumentList "-File .\monitor_vastai_pricing.ps1" -WindowStyle Hidden
```

#### Custom Configuration Examples
```powershell
# Monitor RTX 4090 with 2 GPUs, custom pricing
.\monitor_vastai_pricing.ps1 `
    -TargetGPU "RTX_4090" `
    -TargetNumGPUs 2 `
    -BasePrice 0.40 `
    -MaxPrice 3.00 `
    -IntervalMinutes 15 `
    -PriceStepPercent 15 `
    -HighDemandThreshold 85 `
    -LowDemandThreshold 25

# Monitor RTX 3090 with 4 GPUs in test mode
.\monitor_vastai_pricing.ps1 `
    -TestMode `
    -TargetGPU "RTX_3090" `
    -TargetNumGPUs 4 `
    -IntervalMinutes 5
```

---

## Python Parameters (vastai_autopricer.py)

| Parameter | Default | Description |
|-----------|---------|-------------|
| `--interval` | 10 | Minutes between checks |
| `--base-price` | 0.50 | Minimum price per GPU per hour |
| `--max-price` | 2.00 | Maximum price per GPU per hour |
| `--price-step` | 10 | Percentage to adjust price |
| `--high-demand` | 80 | Market utilization % to increase price |
| `--low-demand` | 30 | Market utilization % to decrease price |
| `--target-gpu` | RTX_5090 | GPU model to monitor |
| `--num-gpus` | 1 | Number of GPUs to filter for |
| `--test-mode` | false | Run without making actual changes |

## Shell Script Parameters (PowerShell/Bash)

| Parameter | Default | Description |
|-----------|---------|-------------|
| `IntervalMinutes` | 10 | How often to check and adjust prices |
| `BasePrice` | 0.50 | Minimum price per GPU per hour |
| `MaxPrice` | 2.00 | Maximum price per GPU per hour |
| `PriceStepPercent` | 10 | Percentage to adjust price each time |
| `HighDemandThreshold` | 80 | Market utilization % to trigger price increase |
| `LowDemandThreshold` | 30 | Market utilization % to trigger price decrease |
| `TargetGPU` | RTX_5090 | GPU model to monitor and reprice |
| `TargetNumGPUs` | 1 | Number of GPUs to filter for |
| `LogFile` | vastai_pricing_log.txt | Path to log file |
| `TestMode` | false | Run without making actual changes |


## How It Works

1. **Market Analysis**: Compares your machine's price against similar GPU offers in the marketplace
2. **Rental Status Check**: Different strategies for rented vs idle machines
3. **Price Decision**:
   - **Rented Machine**: Conservative - only increases price when demand is very high (90%+)
   - **Idle Machine**: Aggressive - diagnoses why idle and adjusts accordingly:
     - Price too high vs market → decrease
     - High demand but not rented → slight increase to find sweet spot
     - Low demand → decrease to attract customers
4. **Safety Check**: Ensures new price stays within min/max bounds
5. **Update**: Applies new price using `vastai set min-bid` command

## Stopping the Script


## Log Files

**Python**: Logs to both `vastai_autopricer.log` and console with timestamps, market analysis, price decisions, and error messages.

**Bash/PowerShell**: Logs to `vastai_pricing_log.txt` with all actions and decisions.
- Foreground: Press `Ctrl+C`
- Background:
```powershell
Get-Process powershell | Where-Object {$_.CommandLine -match "monitor_vastai_pricing"} | Stop-Process
```
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
