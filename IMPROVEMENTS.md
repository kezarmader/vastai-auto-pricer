# Pricing Strategy Improvements

## Overview
Enhanced the auto-pricer to maximize returns while maintaining high occupancy for your Vast.ai machine.

## Key Improvements

### 1. **Market-Based Competitive Pricing**
- **Before**: Simple demand-based pricing (increase/decrease by fixed percentage)
- **After**: Analyzes actual market prices from similar machines
  - Compares with same GPU model (RTX 5090)
  - Same GPU count (1 GPU)
  - Only high-reliability machines (>95%)
  - Calculates: Average, Median, and Minimum prices

### 2. **Smart Pricing Strategy**

#### High Demand (>80% machines rented)
- **Strategy**: Price at 95% of market median
- **Goal**: Maximize profit while staying competitive
- **Logic**: You can charge more when demand is high, but not so much that you price yourself out

#### Medium Demand (30-80% machines rented)
- **Strategy**: Price at 90% of market median
- **Goal**: Balance between profit and occupancy
- **Logic**: Stay competitive with the middle of the market

#### Low Demand (<30% machines rented)
- **Strategy**: Price at 85% of market minimum
- **Goal**: Attract renters and maintain occupancy
- **Logic**: Beat competitors on price to get rentals

### 3. **Occupancy Optimization**
- Automatically lowers price when your GPU sits idle
- Beats competitors on price during low demand
- Ensures you get rentals instead of zero income

### 4. **Maximum Returns**
- Raises price during high demand to maximize profit per hour
- Monitors market continuously to adjust to real-time conditions
- Prevents leaving money on the table

## Example Scenarios

### Scenario 1: High Demand
```
Market: 85% of RTX 5090 x1 machines are rented
Median market price: $0.80/hr
Your action: Set price to $0.76/hr (95% of median)
Result: High chance of rental at premium price
```

### Scenario 2: Low Demand
```
Market: 25% of RTX 5090 x1 machines are rented
Minimum market price: $0.50/hr
Your action: Set price to $0.425/hr (85% of minimum)
Result: Beat competition, get rentals instead of idle GPU
```

### Scenario 3: Medium Demand
```
Market: 50% of RTX 5090 x1 machines are rented
Median market price: $0.65/hr
Your action: Set price to $0.585/hr (90% of median)
Result: Competitive pricing for steady income
```

## Configuration for Your Machine

Your machine: **RTX 5090 x1 (Machine ID: 37958)**

### Recommended Settings
```bash
# Linux
./monitor_vastai_pricing.sh 10 0.40 1.50 10 80 30 false RTX_5090 1

# Parameters explained:
# - Check every 10 minutes
# - Minimum price: $0.40/hr (your floor)
# - Maximum price: $1.50/hr (your ceiling)
# - Price adjustment: 10%
# - High demand: 80%
# - Low demand: 30%
# - Test mode: false (make real changes)
# - Target GPU: RTX_5090
# - Number of GPUs: 1
```

### Test First!
```bash
# Run in test mode to see what it would do
./monitor_vastai_pricing.sh 1 0.40 1.50 10 80 30 true RTX_5090 1
```

## What You'll See in Logs

```
[2025-12-26 22:30:00] === Vast.ai Auto-Pricer Started ===
[2025-12-26 22:30:00] Target GPU: RTX_5090 x1
[2025-12-26 22:30:00] --- Machine 37958 (1 x RTX_5090) | Status: AVAILABLE | Current: $0.50/GPU/hr ---
[2025-12-26 22:30:01] Market analysis: Median=$0.65, Avg=$0.68, Min=$0.55, Rented=45/89
[2025-12-26 22:30:01] Market: 45/89 rented (50.6% demand)
[2025-12-26 22:30:01] Action: DECREASE | Medium demand (50.6%) - aligning with market median | New Price: $0.585/hr
[2025-12-26 22:30:02] SUCCESS: Updated machine 37958 to $0.585/GPU/hr
```

## Benefits

1. **Automated**: No manual price checking needed
2. **Competitive**: Always priced relative to market
3. **Adaptive**: Responds to real-time market conditions
4. **Profitable**: Maximizes income during high demand
5. **Occupied**: Ensures rentals during low demand
6. **Safe**: Respects your min/max price limits

## Next Steps

1. Test in test mode first: `./monitor_vastai_pricing.sh 1 0.40 1.50 10 80 30 true RTX_5090 1`
2. Watch the logs to understand the decisions
3. Adjust min/max prices based on your goals
4. Run in production: `nohup ./monitor_vastai_pricing.sh > /dev/null 2>&1 &`
5. Monitor logs: `tail -f vastai_pricing_log.txt`
