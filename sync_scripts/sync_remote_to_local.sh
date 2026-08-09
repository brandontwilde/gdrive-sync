#!/bin/bash
#
# sync_remote_to_local.sh - Sync changes from Google Drive to local directory
#
# This script is triggered periodically by a systemd timer (every minute) to pull
# changes from Google Drive to the local directory.
#
# Safety features:
# - No delete restrictions (Google Drive is the source of truth)
# - Skips sync if local changes occurred in last 10 seconds (prevents conflicts)
# - Uses lock file to prevent concurrent syncs
# - Retries on MD5 hash mismatches

# Load shared helpers (installed alongside this script), then configuration
source "$(dirname "$0")/lib.sh"
load_config || exit 1

generate_prefix() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') | REMOTE |"
}

cleanup() {
    rm -f "$LOCKFILE"
}

sync_from_drive_to_local() {
    # Get precise timestamp (seconds + nanoseconds)
    get_timestamp() {
        date +%s%N
    }

    # An absent LOCAL_DIR means the config is wrong for this machine. Syncing
    # anyway would create it and mirror the remote into the wrong place.
    # (An *empty* LOCAL_DIR is fine here - that's a first-run pull.)
    require_local_dir || return 1

    # Check if there are pending local changes
    if [ -f "$LAST_CHANGE_FILE" ]; then
        last_change=$(cat "$LAST_CHANGE_FILE")
        current_time=$(get_timestamp)
        time_since_change=$(( (current_time - last_change) / 1000000000 )) # Convert nanoseconds to seconds
        
        # If there was a local change in the last 10 seconds, skip this sync
        if [ $time_since_change -lt 10 ]; then
            echo "$(generate_prefix) Skipping remote sync due to recent local changes ($time_since_change seconds ago)" >> "$LOGFILE"
            return 0
        fi
    fi

    # Acquire lock (held on fd 200 for the duration of the sync)
    exec 200>"$LOCKFILE"
    if ! flock -n 200; then
        echo "$(generate_prefix) WARNING: Another instance is already running, skipping sync" >> "$LOGFILE"
        return
    fi

    # Log the start of the sync
    echo "$(generate_prefix) INFO: Starting sync from Google Drive to local" >> "$LOGFILE"

    local retry_count=0
    while :; do
        # Perform the sync. rclone's exit status is the authoritative result:
        # it retries internally, so its output can contain ERROR lines even when
        # the run ultimately succeeded.
        OUTPUT=$(rclone sync --track-renames "$REMOTE_DIR" "$LOCAL_DIR" 2>&1)
        RC=$?

        if [ $RC -eq 0 ]; then
            echo "$(generate_prefix) SUCCESS: Sync completed" >> "$LOGFILE"
            if [ "$OUTPUT" != "" ]; then
                echo "$(generate_prefix) INFO | $OUTPUT" >> "$LOGFILE"
            fi
            break
        fi

        # Failed. Every failure counts toward MAX_RETRIES so a persistent error
        # (e.g. a Drive quota block) can't spin this loop indefinitely.
        retry_count=$((retry_count + 1))

        if [[ $OUTPUT == *"corrupted on transfer"* ]] || [[ $OUTPUT == *"md5 hashes differ"* ]]; then
            echo "$(generate_prefix) WARNING: MD5 mismatch detected (attempt $retry_count/$MAX_RETRIES)" >> "$LOGFILE"
        else
            echo "$(generate_prefix) WARNING: Sync error, rclone exit $RC (attempt $retry_count/$MAX_RETRIES)" >> "$LOGFILE"
        fi

        if [ $retry_count -ge $MAX_RETRIES ]; then
            echo "$(generate_prefix) ERROR: Sync failed after $retry_count attempts" >> "$LOGFILE"
            echo "$(generate_prefix) ERROR | $OUTPUT" >> "$LOGFILE"
            break
        fi

        echo "$(generate_prefix) INFO: Waiting $RETRY_DELAY seconds before retry..." >> "$LOGFILE"
        sleep $RETRY_DELAY
    done

    # Release lock
    flock -u 200
}

sync_from_drive_to_local
