#!/bin/bash

set -euo pipefail  # Enable safer scripting: exit on error, unset variables are errors, fail on pipe errors

# Ensure the script runs with root privileges
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root. Exiting." >&2
    exit 1
fi

apt install -y build-essential dkms

DRIVER_NAME="dwav-usb-mt"
DRIVER_VERSION="1.0.0"
SRC_DIR="${DRIVER_NAME}-${DRIVER_VERSION}"
DKMS_DIR="/usr/src/${SRC_DIR}"
GRUB_FILE="/etc/default/grub"
QUIRKS_OPTION='usbhid.quirks=0x16b4:0x0704:0x04,0x16b4:0x0705:0x04'

echo "Removing existing DKMS module (if any)..."
dkms remove -m "$DRIVER_NAME" -v "$DRIVER_VERSION" --all || true  # Don't fail if it's not present

# Ensure the source directory exists before copying
if [ ! -d "$SRC_DIR" ]; then
    echo "Source directory $SRC_DIR not found. Exiting." >&2
    exit 1
fi

echo "Copying driver to DKMS source directory..."
cp -a "$SRC_DIR" "$DKMS_DIR"

echo "Adding driver to DKMS..."
dkms add -m "$DRIVER_NAME" -v "$DRIVER_VERSION"

echo "Building driver with DKMS..."
dkms build -m "$DRIVER_NAME" -v "$DRIVER_VERSION"

echo "Installing driver with DKMS..."
dkms install -m "$DRIVER_NAME" -v "$DRIVER_VERSION"

# Handle HID quirks safely
echo "Checking USB HID quirks..."
CURRENT_QUIRKS=$(cat /sys/module/usbhid/parameters/quirks || echo "")
if [[ "$CURRENT_QUIRKS" == *"0x16b4:0x0704:0x04,0x16b4:0x0705:0x04"* ]]; then
    echo "USB HID quirks already configured. No changes needed."
else
    echo "Adding USB HID quirks to GRUB..."

    # Check if the option is already present
    if grep -q "$QUIRKS_OPTION" "$GRUB_FILE"; then
        echo "Quirks already in GRUB configuration."
    else
        # Append to existing GRUB_CMDLINE_LINUX string safely
        sed -i "s/^\(GRUB_CMDLINE_LINUX=\"[^\"]*\)/\1 $QUIRKS_OPTION/" "$GRUB_FILE"
        echo "Updating GRUB..."
        update-grub
        echo "GRUB updated. Please reboot your system for changes to take effect."
    fi
fi

echo "Driver installation and configuration completed successfully!"

