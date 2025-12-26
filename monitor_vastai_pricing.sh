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
    
    # Search for similar offers to gauge market demand
    local search_query="gpu_name=$gpu_name num_gpus=$num_gpus rentable=true"
    local offers=$(vastai search offers "$search_query" --raw 2>/dev/null)
    
    if [ -z "$offers" ] || [ "$offers" = "[]" ]; then
        echo "50"
        return
    fi
    
    # Count total and rented offers
    local total=$(echo "$offers" | jq 'length')
    local rented=$(echo "$offers" | jq '[.[] | select(.rented == true)] | length')
    
    if [ "$total" -eq 0 ]; then
        echo "50"
        return
    fi
    
    # Calculate demand percentage
    local demand_percent=$(echo "scale=1; ($rented * 100) / $total" | bc)
    echo "$demand_percent"
}

calculate_new_price() {
    local current_price="$1"
    local demand_percent="$2"
    local machine_id="$3"
    
    local new_price="$current_price"
    local action="HOLD"
    local reason="Demand: ${demand_percent}%"
    
    # Compare with threshold values
    local is_high=$(echo "$demand_percent >= $HIGH_DEMAND_THRESHOLD" | bc)
    local is_low=$(echo "$demand_percent <= $LOW_DEMAND_THRESHOLD" | bc)
    
    if [ "$is_high" -eq 1 ]; then
        # High demand - increase price
        local increase=$(echo "scale=4; $current_price * ($PRICE_STEP_PERCENT / 100)" | bc)
        new_price=$(echo "scale=4; $current_price + $increase" | bc)
        
        # Cap at max price
        local exceeds_max=$(echo "$new_price > $MAX_PRICE" | bc)
        if [ "$exceeds_max" -eq 1 ]; then
            new_price="$MAX_PRICE"
        fi
        action="INCREASE"
        
    elif [ "$is_low" -eq 1 ]; then
        # Low demand - decrease price
        local decrease=$(echo "scale=4; $current_price * ($PRICE_STEP_PERCENT / 100)" | bc)
        new_price=$(echo "scale=4; $current_price - $decrease" | bc)
        
        # Floor at base price
        local below_min=$(echo "$new_price < $BASE_PRICE" | bc)
        if [ "$below_min" -eq 1 ]; then
            new_price="$BASE_PRICE"
        fi
        action="DECREASE"
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
    local machines=$(vastai show machines --raw 2>/dev/null)
    
    if [ -z "$machines" ] || [ "$machines" = "[]" ]; then
        log_message "No machines found"
        return
    fi
    
    local machine_count=$(echo "$machines" | jq 'length')
    
    for ((i=0; i<machine_count; i++)); do
        local machine=$(echo "$machines" | jq ".[$i]")
        
        local machine_id=$(echo "$machine" | jq -r '.id')
        local gpu_name=$(echo "$machine" | jq -r '.gpu_name' | tr ' ' '_')
        local num_gpus=$(echo "$machine" | jq -r '.num_gpus')
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

# Main script
log_message "=== Vast.ai Auto-Pricer Started ==="
if [ "$TEST_MODE" = "true" ]; then
    log_message "*** RUNNING IN TEST MODE - NO ACTUAL PRICE CHANGES WILL BE MADE ***"
fi
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
