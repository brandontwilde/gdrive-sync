#!/bin/bash
# uninstall.sh - Remove the services, installed scripts, and optionally the
# log file and configuration.

set -u

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run with sudo"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/lib/gdrive-sync}"

ACTUAL_USER=$(who am i | awk '{print $1}')
if [ -z "$ACTUAL_USER" ]; then
    ACTUAL_USER=$(logname)
fi
USER_HOME=$(getent passwd "$ACTUAL_USER" | cut -d: -f6)
CONFIG_DIR="${USER_HOME}/.config/gdrive-sync"
CONFIG_FILE="${CONFIG_DIR}/config.sh"

# Read the config for LOGFILE if it's still there; fall back to the default.
LOGFILE="/var/log/gdrive-sync/gdrive_sync.log"
if [ -f "${SCRIPT_DIR}/sync_scripts/lib.sh" ] && [ -f "$CONFIG_FILE" ]; then
    source "${SCRIPT_DIR}/sync_scripts/lib.sh"
    load_config "$CONFIG_FILE" >/dev/null 2>&1
fi

echo "Stopping and disabling services..."
systemctl stop sync_remote.timer 2>/dev/null
systemctl stop sync_local.service 2>/dev/null
systemctl disable sync_remote.timer 2>/dev/null
systemctl disable sync_local.service 2>/dev/null

echo "Removing systemd unit files..."
rm -f /etc/systemd/system/sync_remote.service
rm -f /etc/systemd/system/sync_remote.timer
rm -f /etc/systemd/system/sync_local.service

# Reload systemd to recognize removed units
systemctl daemon-reload

echo "Removing installed scripts..."
rm -rf "$INSTALL_DIR"

echo "Removing logrotate configuration..."
rm -f /etc/logrotate.d/gdrive_sync

# The log and the config are the only things that hold user state, so ask.
read -p "Remove the log file (${LOGFILE})? [y/N] " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    rm -f "${LOGFILE}"
    echo "Log file removed."
fi

if [ -f "$CONFIG_FILE" ]; then
    read -p "Remove your configuration (${CONFIG_FILE})? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -f "$CONFIG_FILE"
        rmdir "$CONFIG_DIR" 2>/dev/null
        echo "Configuration removed."
    else
        echo "Kept ${CONFIG_FILE}"
    fi
fi

echo ""
echo "Uninstallation complete!"
echo "Your synced files were not touched."
echo "Note: rclone, inotify-tools, and zenity packages were not removed."
echo "If you want to remove them, run: apt remove rclone inotify-tools zenity"
