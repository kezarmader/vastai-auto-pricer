#!/bin/bash

# Vast.ai Auto-Pricer - Uninstallation Script
# This script removes the auto-pricer systemd service

set -e

echo "=== Vast.ai Auto-Pricer Uninstallation ==="
echo ""

SERVICE_FILE="/etc/systemd/system/vastai-pricer.service"

# Check if service exists
if [ ! -f "$SERVICE_FILE" ]; then
    echo "Service not found. Nothing to uninstall."
    exit 0
fi

echo "Stopping and disabling service..."
sudo systemctl stop vastai-pricer.service || true
sudo systemctl disable vastai-pricer.service || true

echo "Removing service file..."
sudo rm -f "$SERVICE_FILE"

echo "Reloading systemd..."
sudo systemctl daemon-reload
sudo systemctl reset-failed

echo ""
echo "=== Uninstallation Complete ==="
echo ""
echo "The auto-pricer service has been removed."
echo "Log files remain in the script directory if you need them."
echo ""
