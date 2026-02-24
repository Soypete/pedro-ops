#!/usr/bin/env bash
# setup-ethernet.sh
# Installs and enables the USB ethernet systemd service on pedrogpt (root@pedrogpt).
# Self-contained: the unit file is embedded below.
# Run: sudo bash setup-ethernet.sh

set -euo pipefail

INTERFACE="enx9c69d319a411"
SERVICE_NAME="usb-ethernet.service"
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

# Write unit file inline (self-contained, no sidecar file needed)
echo "Installing ${SERVICE_NAME} to ${SERVICE_DST}..."
cat > "${SERVICE_DST}" <<'UNIT'
[Unit]
Description=USB Ethernet Setup
Documentation=https://github.com/Soypete/pedro-ops
After=network-pre.target
Before=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/ip link set enx9c69d319a411 up
ExecStart=/usr/sbin/dhcpcd enx9c69d319a411

[Install]
WantedBy=multi-user.target
UNIT

chmod 644 "${SERVICE_DST}"

# Reload and enable
systemctl daemon-reload
systemctl enable "${SERVICE_NAME}"
systemctl start "${SERVICE_NAME}"

echo "Done. ${SERVICE_NAME} is enabled and started."
echo "Verify with: systemctl status ${SERVICE_NAME}"
