#!/bin/bash

# Vast.ai Auto-Pricer
# Monitors demand and automatically adjusts pricing for your Vast.ai hosted machines

# Configuration
INTERVAL_MINUTES=${1:-10}
LOG_FILE="vastai_pricing_log.txt"
BASE_PRICE=${2:-0.50}
MAX_PRICE=${3:-2.00}
PRICE_STEP_PERCENT=${4:-10}
HIGH_DEMAND_THRESHOLD=${5:-80}
LOW_DEMAND_THRESHOLD=${6:-30}
TEST_MODE=${7:-false}
TARGET_GPU=${8:-RTX_5090}      # Filter for specific GPU model
TARGET_NUM_GPUS=${9:-1}        # Filter for specific number of GPUs

# Arrays to store state
declare -A last_utilization
declare -A price_history

log_message() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $message" | tee -a "$LOG_FILE"
}

get_market_demand() {
    local gpu_name="$1"
    local num_gpus="$2"
    
    # Search for similar offers - same GPU, count, good reliability
    local search_query="gpu_name=$TARGET_GPU num_gpus=$TARGET_NUM_GPUS rentable=true reliability>0.95"
    local offers=$(vastai search offers "$search_query" --raw 2>/dev/null)
    
    if [ -z "$offers" ] || [ "$offers" = "[]" ]; then
        echo "50|null|null|null|0|0"
        return
    fi
    
    # Count total and rented offers
    local total=$(echo "$offers" | jq 'length')
    local rented=$(echo "$offers" | jq '[.[] | select(.rented == true)] | length')
    
    if [ "$total" -eq 0 ]; then
        echo "50|null|null|null|0|0"
        return
    fi
    
    # Calculate demand percentage
    local demand_percent=$(echo "scale=1; ($rented * 100) / $total" | bc)
    
    # Get pricing data from available (not rented) machines
    local prices=$(echo "$offers" | jq -r '[.[] | select(.rented == false) | .dph_base | select(. > 0)] | sort | @csv' | tr -d '"' | tr ',' '\n')
    
    if [ -z "$prices" ]; then
        echo "${demand_percent}|null|null|null|$rented|$total"
        return
    fi
    
    # Calculate price statistics
    local avg_price=$(echo "$prices" | awk '{sum+=$1; count++} END {if(count>0) printf "%.4f", sum/count; else print "null"}')
    local min_price=$(echo "$prices" | sort -n | head -1 | xargs printf "%.4f")
    local median_price=$(echo "$prices" | sort -n | awk '{prices[NR]=$1} END {if(NR%2==1) printf "%.4f", prices[(NR+1)/2]; else printf "%.4f", (prices[NR/2]+prices[NR/2+1])/2}')
    
    echo "${demand_percent}|${avg_price}|${median_price}|${min_price}|$rented|$total"
}

calculate_new_price() {
    local current_price="$1"
    local market_data="$2"
    local machine_id="$3"
    
    # Parse market data: demand|avg|median|min|rented|total
    IFS='|' read -r demand_percent avg_price median_price min_price rented_count total_count <<< "$market_data"
    
    local new_price="$current_price"
    local action="HOLD"
    local reason="Demand: ${demand_percent}%"
    
    log_message "Market analysis: Median=\$$median_price, Avg=\$$avg_price, Min=\$$min_price, Rented=$rented_count/$total_count"
    
    # Strategy: Price competitively based on market conditions
    if [ "$median_price" != "null" ] && [ "$avg_price" != "null" ]; then
        local is_high=$(echo "$demand_percent >= $HIGH_DEMAND_THRESHOLD" | bc)
        local is_low=$(echo "$demand_percent <= $LOW_DEMAND_THRESHOLD" | bc)
        
        if [ "$is_high" -eq 1 ]; then
            # High demand: Price at 95% of median
            local target_price=$(echo "scale=4; $median_price * 0.95" | bc)
            target_price=$(echo "if ($target_price > $MAX_PRICE) $MAX_PRICE else if ($target_price < $BASE_PRICE) $BASE_PRICE else $target_price" | bc)
            
            local price_increased=$(echo "$target_price > $current_price" | bc)
            if [ "$price_increased" -eq 1 ]; then
                new_price="$target_price"
                action="INCREASE"
                reason="High demand (${demand_percent}%) - pricing at 95% of market median"
            fi
            
        elif [ "$is_low" -eq 1 ]; then
            # Low demand: Price at 85% of minimum
            local target_price=$(echo "scale=4; $min_price * 0.85" | bc)
            target_price=$(echo "if ($target_price < $BASE_PRICE) $BASE_PRICE else if ($target_price > $MAX_PRICE) $MAX_PRICE else $target_price" | bc)
            
            local price_decreased=$(echo "$target_price < $current_price" | bc)
            if [ "$price_decreased" -eq 1 ]; then
                new_price="$target_price"
                action="DECREASE"
                reason="Low demand (${demand_percent}%) - pricing at 85% of market minimum"
            fi
            
        else
            # Medium demand: Price around 90% of median
            local target_price=$(echo "scale=4; $median_price * 0.90" | bc)
            target_price=$(echo "if ($target_price > $MAX_PRICE) $MAX_PRICE else if ($target_price < $BASE_PRICE) $BASE_PRICE else $target_price" | bc)
            
            local price_diff=$(echo "scale=4; if ($target_price > $current_price) $target_price - $current_price else $current_price - $target_price" | bc)
            local threshold=$(echo "scale=4; $current_price * 0.05" | bc)
            local should_adjust=$(echo "$price_diff > $threshold" | bc)
            
            if [ "$should_adjust" -eq 1 ]; then
                new_price="$target_price"
                local is_increase=$(echo "$target_price > $current_price" | bc)
                action=$([ "$is_increase" -eq 1 ] && echo "INCREASE" || echo "DECREASE")
                reason="Medium demand (${demand_percent}%) - aligning with market median"
            fi
        fi
    else
        # Fallback to simple demand-based pricing
        log_message "No market pricing data, using demand-based strategy"
        
        local is_high=$(echo "$demand_percent >= $HIGH_DEMAND_THRESHOLD" | bc)
        local is_low=$(echo "$demand_percent <= $LOW_DEMAND_THRESHOLD" | bc)
        
        if [ "$is_high" -eq 1 ]; then
            local increase=$(echo "scale=4; $current_price * ($PRICE_STEP_PERCENT / 100)" | bc)
            new_price=$(echo "scale=4; $current_price + $increase" | bc)
            new_price=$(echo "if ($new_price > $MAX_PRICE) $MAX_PRICE else $new_price" | bc)
            action="INCREASE"
            reason="High demand (${demand_percent}%) - no market data"
            
        elif [ "$is_low" -eq 1 ]; then
            local decrease=$(echo "scale=4; $current_price * ($PRICE_STEP_PERCENT / 100)" | bc)
            new_price=$(echo "scale=4; $current_price - $decrease" | bc)
            new_price=$(echo "if ($new_price < $BASE_PRICE) $BASE_PRICE else $new_price" | bc)
            action="DECREASE"
            reason="Low demand (${demand_percent}%) - no market data"
        fi
    fi
    
    echo "$new_price|$action|$reason"
}

update_machine_price() {
    local machine_id="$1"
    local new_price="$2"
    
    if [ "$TEST_MODE" = "true" ]; then
        log_message "TEST MODE: Would update machine $machine_id to \$$new_price/GPU/hr"
        return 0
    fi
    
    local result=$(vastai set min-bid "$machine_id" --price "$new_price" --raw 2>&1)
    
    if echo "$result" | jq -e '.success' >/dev/null 2>&1; then
        log_message "SUCCESS: Updated machine $machine_id to \$$new_price/GPU/hr"
        return 0
    else
        log_message "FAILED: Could not update machine $machine_id - $result"
        return 1
    fi
}

monitor_and_reprice() {
        log_message "--- Machine $machine_id ($num_gpus x $gpu_name) | Status: $rented_str | Current: \$$current_price/GPU/hr ---"
        
        # Get market demand and pricing data
        local market_data=$(get_market_demand "$gpu_name" "$num_gpus")
        IFS='|' read -r demand_percent avg_price median_price min_price rented_count total_count <<< "$market_data"
        log_message "Market: $rented_count/$total_count rented (${demand_percent}% demand)"
        
        # Calculate new price based on market conditions
        local result=$(calculate_new_price "$current_price" "$market_data" "$machine_id")
    local machines=$(echo "$response" | jq -r '.machines')
    
    if [ -z "$machines" ] || [ "$machines" = "[]" ] || [ "$machines" = "null" ]; then
        log_message "No machines found"
        return
    fi
    
    # Get machine count
    local machine_count=$(echo "$machines" | jq 'length')
    
    if [ "$machine_count" -eq 0 ]; then
        log_message "No machines found"
        return
    fi
    
    for ((i=0; i<machine_count; i++)); do
        local machine=$(echo "$machines" | jq ".[$i]")
        
        
        local current_price=$(echo "$machine" | jq -r '.min_bid_price')
        local is_rented=$(echo "$machine" | jq -r 'if .current_rentals_running > 0 then "true" else "false" end')
        local gpu_name=$(echo "$machine" | jq -r '.gpu_name' | tr ' ' '_')
        local num_gpus=$(echo "$machine" | jq -r '.num_gpus')
        
        # Skip machines that don't match target GPU and count
        if [ "$gpu_name" != "$TARGET_GPU" ] || [ "$num_gpus" -ne "$TARGET_NUM_GPUS" ]; then
            continue
        fi
        local current_price=$(echo "$machine" | jq -r '.min_bid')
        local is_rented=$(echo "$machine" | jq -r '.rented')
        
        local rented_str="AVAILABLE"
        if [ "$is_rented" = "true" ]; then
            rented_str="RENTED"
        fi
        
        log_message "--- Machine $machine_id ($num_gpus x $gpu_name) | Status: $rented_str | Current: \$$current_price/GPU/hr ---"
        
        # Get market demand
        local demand_percent=$(get_market_demand "$gpu_name" "$num_gpus")
        log_message "Market demand for $gpu_name (x$num_gpus): ${demand_percent}%"
        
        # Calculate new price
        local result=$(calculate_new_price "$current_price" "$demand_percent" "$machine_id")
        local new_price=$(echo "$result" | cut -d'|' -f1)
        local action=$(echo "$result" | cut -d'|' -f2)
        local reason=$(echo "$result" | cut -d'|' -f3)
        
        if [ "$action" != "HOLD" ]; then
            log_message "Action: $action | $reason | New Price: \$$new_price/GPU/hr"
            update_machine_price "$machine_id" "$new_price"
        else
            log_message "Action: HOLD | $reason | Price unchanged: \$$current_price/GPU/hr"
        fi
    done
}

# Display usage if --help is passed
if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    echo "Usage: $0 [interval] [basePrice] [maxPrice] [priceStep%] [highThreshold] [lowThreshold] [testMode] [targetGPU] [numGPUs]"
    echo ""
    echo "Arguments (all optional, shown with defaults):"
    echo "  1. interval          Check interval in minutes (default: 10)"
    echo "  2. basePrice         Minimum price per GPU/hr (default: 0.50)"
    echo "  3. maxPrice          Maximum price per GPU/hr (default: 2.00)"
    echo "  4. priceStep%        Price adjustment percentage (default: 10)"
    echo "  5. highThreshold     High demand threshold % (default: 80)"
    echo "  6. lowThreshold      Low demand threshold % (default: 30)"
    echo "  7. testMode          Run without changes: true/false (default: false)"
    echo "  8. targetGPU         GPU model to monitor (default: RTX_5090)"
    echo "  9. numGPUs           Number of GPUs (default: 1)"
    echo ""
    echo "Example: $0 15 0.40 3.00 15 85 25 true RTX_4090 2"
    exit 0
fi

# Main script
log_message "=== Vast.ai Auto-Pricer Started ==="
if [ "$TEST_MODE" = "true" ]; then
    log_message "*** RUNNING IN TEST MODE - NO ACTUAL PRICE CHANGES WILL BE MADE ***"
fi
log_message "Target GPU: $TARGET_GPU x$TARGET_NUM_GPUS"
log_message "Check interval: $INTERVAL_MINUTES minutes"
log_message "Base price: \$$BASE_PRICE | Max price: \$$MAX_PRICE | Price step: ${PRICE_STEP_PERCENT}%"
log_message "High demand threshold: ${HIGH_DEMAND_THRESHOLD}% | Low demand threshold: ${LOW_DEMAND_THRESHOLD}%"
log_message "Log file: $LOG_FILE"
log_message ""

while true; do
    monitor_and_reprice
    log_message ""
    sleep $((INTERVAL_MINUTES * 60))
done
