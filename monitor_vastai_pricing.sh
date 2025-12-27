#!/bin/bash

# Vast.ai Auto-Pricer - Shell Wrapper
# This is a simple wrapper that calls the Python auto-pricer with bash-style arguments

# Parse arguments (bash style)
INTERVAL_MINUTES=${1:-10}
BASE_PRICE=${2:-0.50}
MAX_PRICE=${3:-2.00}
TEST_MODE=${4:-false}
TARGET_GPU=${5:-RTX_5090}
TARGET_NUM_GPUS=${6:-1}

# Show help
if [ "$1" == "--help" ] || [ "$1" == "-h" ]; then
    echo "Vast.ai Auto-Pricer (Python-based)"
    echo ""
    echo "Usage: $0 [interval] [basePrice] [maxPrice] [testMode] [targetGPU] [numGPUs]"
    echo ""
    echo "Arguments:"
    echo "  interval        Minutes between checks (default: 10)"
    echo "  basePrice       Minimum price per GPU/hour (default: 0.50)"
    echo "  maxPrice        Maximum price per GPU/hour (default: 2.00)"
    echo "  testMode        true/false - test without changes (default: false)"
    echo "  targetGPU       GPU model to monitor (default: RTX_5090)"
    echo "  numGPUs         Number of GPUs to filter (default: 1)"
    echo ""
    echo "Examples:"
    echo "  $0                                # Use all defaults"
    echo "  $0 5 0.40 3.00 false              # Custom settings"
    echo "  $0 1 0.50 2.00 true               # Test mode"
    exit 0
fi

# Build Python command with arguments
PYTHON_CMD="python3 vastai_autopricer.py"
PYTHON_CMD="$PYTHON_CMD --interval $INTERVAL_MINUTES"
PYTHON_CMD="$PYTHON_CMD --base-price $BASE_PRICE"
PYTHON_CMD="$PYTHON_CMD --max-price $MAX_PRICE"
PYTHON_CMD="$PYTHON_CMD --target-gpu $TARGET_GPU"
PYTHON_CMD="$PYTHON_CMD --num-gpus $TARGET_NUM_GPUS"

# Add test mode flag if enabled
if [ "$TEST_MODE" == "true" ]; then
    PYTHON_CMD="$PYTHON_CMD --test-mode"
fi

# Show what we're running
echo "Starting Vast.ai Auto-Pricer (Python version)..."
echo "Command: $PYTHON_CMD"
echo ""

# Execute the Python script
exec python3 -u $PYTHON_CMD
