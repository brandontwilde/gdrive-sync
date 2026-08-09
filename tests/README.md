# Tests

This directory contains test scripts for the gdrive-sync tool.

## test_safety.sh

Tests the safety mechanisms that prevent accidental data loss.

**What it tests:**
- Normal syncs (no deletes)
- Small deletes (under threshold)
- Large deletes (should trigger confirmation dialog)
- Catastrophic deletes (empty local folder)
- Rename detection (renames shouldn't count as deletes)
- Zenity dialog functionality

**How to run:**
```bash
cd /path/to/gdrive-sync
./tests/test_safety.sh
```

The test uses temporary directories in `/tmp/gdrive_sync_test` and will not touch your actual files.

## test_lib.sh

Unit tests for `sync_scripts/lib.sh` — config loading, defaults, and the
`LOCAL_DIR` guards. Fast, no network, no sync.

**What it tests:**
- `load_config` fails clearly on a missing `config.sh`, or a missing `LOCAL_DIR` / `REMOTE_DIR`
- Optional settings fall back to safe defaults; explicit values are not overridden
- `require_local_dir` rejects a nonexistent path
- `require_local_dir_not_empty` rejects an empty vault (the case that would wipe
  the remote) and correctly treats a hidden-only directory like `.obsidian` as non-empty

**How to run:**
```bash
./tests/test_lib.sh
```

## test_sync_remote.sh

Unit tests for `sync_scripts/sync_remote_to_local.sh`. Unlike `test_safety.sh`, these
run the real script unmodified and are fully automated — no prompts, no GUI, no network.

**How it works:**
- The script is copied into a throwaway project dir at `/tmp/gdrive_sync_unit_test`
  alongside a test `config.sh`, so the script's `$(dirname $(dirname $0))/config.sh`
  lookup picks up test paths instead of your real vault and log file.
- A fake `rclone` is placed first on `PATH`, so sync outcomes (slow, md5 mismatch,
  quota error, noisy success) are scripted and deterministic.

**What it tests:**
- Locking: exits 0 with no `flock` errors, the lock is actually held for the duration
  of the sync, it is released afterward, and a concurrent run is skipped rather than raced
- Debounce: skips when a local change happened <10s ago, syncs otherwise
- Retries: bounded at `MAX_RETRIES` for both md5 mismatches and other errors,
  and recovers from transient failures
- Success detection: an rclone run that exits 0 but prints `ERROR` lines (rclone's own
  internal retries) is treated as success, not retried
- Config guards: refuses to pull into a nonexistent `LOCAL_DIR` (without creating it),
  still allows an empty one (a first-run pull), exits non-zero on a missing `config.sh`,
  and applies defaults for absent settings

**How to run:**
```bash
./tests/test_sync_remote.sh
```

Exits 0 if all tests pass, 1 otherwise. To check the suite still catches a regression,
point it at an older copy of the script:

```bash
GDRIVE_SYNC_SCRIPT=/path/to/old/sync_remote_to_local.sh ./tests/test_sync_remote.sh
```
