#!/bin/bash

# Vast.ai Auto-Pricer - Installation Script
# This script sets up the auto-pricer to run automatically on system boot

set -e

echo "=== Vast.ai Auto-Pricer Installation ==="
echo ""

# Get the absolute path to the script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_SCRIPT="$SCRIPT_DIR/vastai_autopricer.py"
WRAPPER_SCRIPT="$SCRIPT_DIR/monitor_vastai_pricing.sh"

# Get current user
CURRENT_USER=$(whoami)

# Default configuration
INTERVAL=${1:-10}
BASE_PRICE=${2:-0.50}
MAX_PRICE=${3:-2.00}
TARGET_GPU=${4:-RTX_5090}
NUM_GPUS=${5:-1}

echo "Configuration:"
echo "  User: $CURRENT_USER"
echo "  Script Directory: $SCRIPT_DIR"
echo "  Interval: $INTERVAL minutes"
echo "  Base Price: \$$BASE_PRICE/hr"
echo "  Max Price: \$$MAX_PRICE/hr"
echo "  Target GPU: $TARGET_GPU"
echo "  Number of GPUs: $NUM_GPUS"
echo ""

# Check if Python3 is installed
if ! command -v python3 &> /dev/null; then
    echo "ERROR: python3 is not installed. Please install Python 3.x first."
    exit 1
fi

# Check if vastai CLI is installed
if ! command -v vastai &> /dev/null; then
    echo "WARNING: vastai CLI not found. Please install it first:"
    echo "  pip install vast-ai"
    echo ""
fi

# Make scripts executable
echo "Making scripts executable..."
chmod +x "$WRAPPER_SCRIPT"
chmod +x "$PYTHON_SCRIPT"

# Create systemd service file
SERVICE_FILE="/etc/systemd/system/vastai-pricer.service"

echo ""
echo "Creating systemd service..."
echo "This requires sudo access."

sudo tee "$SERVICE_FILE" > /dev/null <<EOF
[Unit]
Description=Vast.ai Auto-Pricer
After=network.target

[Service]
Type=simple
User=$CURRENT_USER
WorkingDirectory=$SCRIPT_DIR
ExecStart=/usr/bin/python3 $PYTHON_SCRIPT --interval $INTERVAL --base-price $BASE_PRICE --max-price $MAX_PRICE --target-gpu $TARGET_GPU --num-gpus $NUM_GPUS
Restart=always
RestartSec=30
StandardOutput=append:$SCRIPT_DIR/vastai_pricer.log
StandardError=append:$SCRIPT_DIR/vastai_pricer_error.log

[Install]
WantedBy=multi-user.target
EOF

echo "Service file created at: $SERVICE_FILE"

# Reload systemd, enable and start the service
echo ""
echo "Enabling and starting service..."
sudo systemctl daemon-reload
sudo systemctl enable vastai-pricer.service
sudo systemctl start vastai-pricer.service

# Check status
echo ""
echo "Service status:"
sudo systemctl status vastai-pricer.service --no-pager

echo ""
echo "=== Installation Complete ==="
echo ""
echo "The auto-pricer is now running and will start automatically on boot."
echo ""
echo "Useful commands:"
echo "  Check status:   sudo systemctl status vastai-pricer.service"
echo "  View logs:      tail -f $SCRIPT_DIR/vastai_pricer.log"
echo "  Stop service:   sudo systemctl stop vastai-pricer.service"
echo "  Start service:  sudo systemctl start vastai-pricer.service"
echo "  Restart:        sudo systemctl restart vastai-pricer.service"
echo "  Disable:        sudo systemctl disable vastai-pricer.service"
echo "  View live logs: journalctl -u vastai-pricer.service -f"
echo ""
