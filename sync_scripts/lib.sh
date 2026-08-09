#!/bin/bash
#
# lib.sh - Shared config loading, defaults, and safety guards for the sync scripts.
#
# The sourcing script must define generate_prefix() before calling the guard
# functions, since they log through it.

# Where config.sh lives. Not in the repo: the repo is source, and an installed
# copy of these scripts runs from elsewhere.
#   1. an explicit path argument (tests, tooling)
#   2. $GDRIVE_SYNC_CONFIG (set in the systemd units)
#   3. the XDG default
config_path() {
    if [ -n "$1" ]; then
        echo "$1"
    elif [ -n "$GDRIVE_SYNC_CONFIG" ]; then
        echo "$GDRIVE_SYNC_CONFIG"
    else
        echo "${XDG_CONFIG_HOME:-$HOME/.config}/gdrive-sync/config.sh"
    fi
}

# Load the config, apply defaults, and validate the settings we cannot safely
# guess.
#
# Runs before LOGFILE is known, so failures go to stderr (systemd captures it).
# Returns non-zero if the config is unusable; callers must exit on failure.
load_config() {
    local config_file
    config_file="$(config_path "$1")"

    if [ ! -f "$config_file" ]; then
        echo "gdrive-sync: no config at $config_file" >&2
        echo "gdrive-sync: run install.sh, or copy config.sh.example there and set LOCAL_DIR" >&2
        return 1
    fi

    source "$config_file"

    # Defaults for everything optional, so a config that predates a new setting
    # fails safe instead of leaving it empty. An unset MAX_DELETE_COUNT used to
    # make the delete guard fail *open*: [ 400 -gt "" ] errors, the if evaluates
    # false, and the sync proceeds to delete unprompted.
    MAX_DELETE_COUNT="${MAX_DELETE_COUNT:-5}"
    MAX_RETRIES="${MAX_RETRIES:-5}"
    RETRY_DELAY="${RETRY_DELAY:-5}"
    DEBOUNCE_DELAY="${DEBOUNCE_DELAY:-4}"
    LOCKFILE="${LOCKFILE:-/tmp/gdrive_sync.lock}"
    LAST_CHANGE_FILE="${LAST_CHANGE_FILE:-/tmp/gdrive_last_change}"
    SYNC_DISABLED_FILE="${SYNC_DISABLED_FILE:-/tmp/gdrive_sync_disabled}"
    LOGFILE="${LOGFILE:-/var/log/gdrive-sync/gdrive_sync.log}"

    # No sensible default exists for these two: guessing a path is how a vault
    # ends up mirrored into the wrong directory.
    if [ -z "$LOCAL_DIR" ]; then
        echo "gdrive-sync: LOCAL_DIR is not set in $config_file" >&2
        return 1
    fi

    if [ -z "$REMOTE_DIR" ]; then
        echo "gdrive-sync: REMOTE_DIR is not set in $config_file" >&2
        return 1
    fi

    return 0
}

# Refuse to sync when LOCAL_DIR does not exist.
#
# A path that isn't there almost always means the config is wrong for this
# machine - a config from another host, or a rename that only happened on one
# of them. rclone would happily create the directory and mirror the whole
# remote into it, leaving the real vault behind and unsynced.
require_local_dir() {
    if [ ! -d "$LOCAL_DIR" ]; then
        echo "$(generate_prefix) ERROR: LOCAL_DIR does not exist: $LOCAL_DIR. Refusing to sync." >> "$LOGFILE"
        return 1
    fi
    return 0
}

# Refuse to push when LOCAL_DIR is empty.
#
# Only meaningful for local-to-remote: an empty vault is indistinguishable from
# one that was just wiped, and syncing that upward propagates the wipe to Drive.
# Remote-to-local deliberately does not call this - an empty local directory is
# the normal state on a fresh install pulling the vault down for the first time.
require_local_dir_not_empty() {
    if [ -z "$(find "$LOCAL_DIR" -mindepth 1 -print -quit 2>/dev/null)" ]; then
        echo "$(generate_prefix) ERROR: LOCAL_DIR is empty: $LOCAL_DIR. Refusing to sync (this would delete everything on the remote)." >> "$LOGFILE"
        return 1
    fi
    return 0
}
