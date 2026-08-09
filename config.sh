#!/bin/bash
#
# config.sh - Configuration file for gdrive-sync
#
# WARNING: This file is read by the sync scripts while they are running.
# Changes to this file will take effect immediately.
# Be careful when modifying paths while syncing is active as it could
# lead to unexpected behavior. It's safer to stop the services first:
#   sudo systemctl stop sync_local.service sync_remote.timer

# ============================================================================
# Directory Configuration
# ============================================================================
LOCAL_DIR="/home/brandon/obsidian-vault"  # Local directory to sync
REMOTE_DIR="gdrive_obsidian:Obsidian"    # rclone remote in format "remote_name:folder"

# ============================================================================
# Sync Behavior Settings
# ============================================================================
RETRY_DELAY=5      # Seconds to wait between retry attempts
MAX_RETRIES=5      # Maximum number of retries on sync errors
DEBOUNCE_DELAY=4   # Seconds to wait after file change before syncing (prevents rapid syncs)

# ============================================================================
# Safety Settings (only applied to local-to-remote sync)
# ============================================================================
MAX_DELETE_COUNT=5                          # Prompt user if more than this many files would be deleted
SYNC_DISABLED_FILE="/tmp/gdrive_sync_disabled"  # Created when user cancels abnormal sync

# ============================================================================
# System Files
# ============================================================================
LOCKFILE="/tmp/gdrive_sync.lock"
LAST_CHANGE_FILE="/tmp/gdrive_last_change"
LOGFILE="/var/log/gdrive-sync/gdrive_sync.log"
