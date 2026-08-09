#!/bin/bash
# install.sh - Install the sync scripts, services, and configuration
#
# This repository is source only. Nothing runs from the clone: the scripts are
# installed to INSTALL_DIR and the systemd units point there, so editing or
# switching branches in the clone cannot disturb a running sync. Re-run this
# script to deploy changes.

set -u

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run with sudo"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/lib/gdrive-sync}"

# Get the actual user who ran sudo
ACTUAL_USER=$(who am i | awk '{print $1}')
if [ -z "$ACTUAL_USER" ]; then
    ACTUAL_USER=$(logname)
fi
USER_HOME=$(getent passwd "$ACTUAL_USER" | cut -d: -f6)
CONFIG_DIR="${USER_HOME}/.config/gdrive-sync"
CONFIG_FILE="${CONFIG_DIR}/config.sh"

SOURCE_FILES=(
    "sync_scripts/lib.sh"
    "sync_scripts/sync_remote_to_local.sh"
    "sync_scripts/sync_local_to_remote.sh"
)

check_requirements() {
    local missing_requirements=0

    echo "Checking for required files..."
    for file in "${SOURCE_FILES[@]}" "config.sh.example"; do
        if [[ ! -f "${SCRIPT_DIR}/${file}" ]]; then
            echo "Error: ${file} not found"
            missing_requirements=1
        fi
    done

    if ! command -v rclone >/dev/null 2>&1; then
        echo "Error: rclone is not installed. Please install and configure rclone before running this script."
        echo "See the README for instructions."
        missing_requirements=1
    fi

    if [[ $missing_requirements -eq 1 ]]; then
        echo "Required files or commands are missing. Please ensure all requirements are met before running this script."
        exit 1
    fi
}

# Put config.sh in the user's config directory, seeding it on first install.
# Earlier versions kept it in the clone; move it across if it's still there.
setup_config() {
    install -d -m 755 -o "$ACTUAL_USER" -g "$ACTUAL_USER" "$CONFIG_DIR"

    if [ -f "$CONFIG_FILE" ]; then
        return 0
    fi

    if [ -f "${SCRIPT_DIR}/config.sh" ]; then
        echo "Found a config.sh in the repository (from an older install)."
        echo "Moving it to ${CONFIG_FILE}"
        mv "${SCRIPT_DIR}/config.sh" "$CONFIG_FILE"
        chown "${ACTUAL_USER}:${ACTUAL_USER}" "$CONFIG_FILE"
        return 0
    fi

    install -m 644 -o "$ACTUAL_USER" -g "$ACTUAL_USER" \
        "${SCRIPT_DIR}/config.sh.example" "$CONFIG_FILE"
    echo ""
    echo "Created ${CONFIG_FILE} from config.sh.example."
    echo "Edit it to set LOCAL_DIR for this machine, then re-run this script."
    exit 0
}

check_requirements
setup_config

# Load the config we just placed, with defaults and validation
source "${SCRIPT_DIR}/sync_scripts/lib.sh"
load_config "$CONFIG_FILE" || exit 1

# Stop the services before replacing their scripts. bash reads a script lazily
# while executing it, so overwriting the files under a running daemon can make
# it execute a mix of old and new code.
echo "Stopping services (if running)..."
systemctl stop sync_local.service 2>/dev/null
systemctl stop sync_remote.timer 2>/dev/null

# Install required packages
echo "Installing dependencies..."
apt update
apt install -y inotify-tools zenity

# Create log directory and file with proper permissions
install -d -m 755 -o "$ACTUAL_USER" -g "$ACTUAL_USER" "$(dirname "$LOGFILE")"
if [ ! -f "$LOGFILE" ]; then
    install -m 640 -o "$ACTUAL_USER" -g "$ACTUAL_USER" /dev/null "$LOGFILE"
fi

# Create the sync directory. Confirm first when it doesn't exist: a typo here
# is silent, and the sync scripts will (correctly) refuse to run against a path
# that isn't the real vault.
if [ ! -d "${LOCAL_DIR}" ]; then
    echo ""
    echo "LOCAL_DIR does not exist: ${LOCAL_DIR}"
    echo "If that is not the path you meant, answer no and fix LOCAL_DIR in ${CONFIG_FILE}."
    read -r -p "Create it? [y/N] " reply
    if [[ ! "$reply" =~ ^[Yy]$ ]]; then
        echo "Aborting. No changes made to ${LOCAL_DIR}."
        exit 1
    fi
    mkdir -p "${LOCAL_DIR}"
fi
chown "${ACTUAL_USER}:${ACTUAL_USER}" "${LOCAL_DIR}"

# Install the scripts
echo "Installing scripts to ${INSTALL_DIR}..."
install -d -m 755 "$INSTALL_DIR"
for file in "${SOURCE_FILES[@]}"; do
    install -m 755 "${SCRIPT_DIR}/${file}" "${INSTALL_DIR}/$(basename "$file")"
done

# Record what was installed, so a clone that has moved on is easy to spot
if git -C "$SCRIPT_DIR" rev-parse --short HEAD >/dev/null 2>&1; then
    git -C "$SCRIPT_DIR" rev-parse --short HEAD > "${INSTALL_DIR}/VERSION"
else
    echo "unknown" > "${INSTALL_DIR}/VERSION"
fi

# Generate systemd units directly into place. They pass the config path
# explicitly rather than relying on $HOME being set for the service.
echo "Installing systemd unit files..."
cat > /etc/systemd/system/sync_remote.service << EOL
[Unit]
Description=Sync from Google Drive to local directory
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment="RCLONE_CONFIG=${USER_HOME}/.config/rclone/rclone.conf"
Environment="GDRIVE_SYNC_CONFIG=${CONFIG_FILE}"
ExecStart=${INSTALL_DIR}/sync_remote_to_local.sh
User=${ACTUAL_USER}
Group=${ACTUAL_USER}

[Install]
WantedBy=multi-user.target
EOL

cat > /etc/systemd/system/sync_remote.timer << EOL
[Unit]
Description=Sync from Google Drive to local directory every minute

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min

[Install]
WantedBy=timers.target
EOL

cat > /etc/systemd/system/sync_local.service << EOL
[Unit]
Description=Monitor and sync local directory to Google Drive
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment="RCLONE_CONFIG=${USER_HOME}/.config/rclone/rclone.conf"
Environment="GDRIVE_SYNC_CONFIG=${CONFIG_FILE}"
ExecStart=${INSTALL_DIR}/sync_local_to_remote.sh
User=${ACTUAL_USER}
Group=${ACTUAL_USER}
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOL

# Install logrotate configuration
echo "Installing logrotate configuration..."
cat > /etc/logrotate.d/gdrive_sync << EOL
${LOGFILE} {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 640 ${ACTUAL_USER} ${ACTUAL_USER}
}
EOL

# Reload systemd to pick up new units
systemctl daemon-reload

echo "Enabling and starting systemd services..."
systemctl enable --now sync_remote.timer
systemctl enable --now sync_local.service

echo ""
echo "Installation complete: $(cat "${INSTALL_DIR}/VERSION")"
echo "  scripts: ${INSTALL_DIR}"
echo "  config:  ${CONFIG_FILE}"
echo "  log:     ${LOGFILE}"
echo ""
echo "Nothing runs from this clone. Re-run 'sudo ./install.sh' to deploy changes."
