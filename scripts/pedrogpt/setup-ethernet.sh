#!/usr/bin/env bash
# setup-ethernet.sh
# Installs and enables the USB ethernet systemd service on pedrogpt (root@pedrogpt).
# Run this script once after first boot or after OS reinstall.
#
# Usage: sudo bash setup-ethernet.sh
#
# The interface enx9c69d319a411 is the USB ethernet adapter providing LAN
# connectivity. This script makes it persistent across reboots without
# relying on NetworkManager.

set -euo pipefail

INTERFACE="enx9c69d319a411"
SERVICE_NAME="usb-ethernet.service"
SERVICE_SRC="$(dirname "$0")/${SERVICE_NAME}"
SERVICE_DST="/etc/systemd/system/${SERVICE_NAME}"

if [[ $EUID -ne 0 ]]; then
  echo "Error: this script must be run as root." >&2
  exit 1
fi

# Verify the interface exists
if ! ip link show "${INTERFACE}" &>/dev/null; then
  echo "Warning: interface ${INTERFACE} not found. Make sure the USB ethernet adapter is connected."
fi

# Install dhcpcd if missing
if ! command -v dhcpcd &>/dev/null; then
  echo "dhcpcd not found — installing..."
  apt-get install -y dhcpcd5
fi

# Copy unit file
echo "Installing ${SERVICE_NAME} to ${SERVICE_DST}..."
cp "${SERVICE_SRC}" "${SERVICE_DST}"
chmod 644 "${SERVICE_DST}"

# Reload and enable
systemctl daemon-reload
systemctl enable "${SERVICE_NAME}"
systemctl start "${SERVICE_NAME}"

echo "Done. ${SERVICE_NAME} is enabled and started."
echo "Verify with: systemctl status ${SERVICE_NAME}"
