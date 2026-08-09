#!/bin/bash
# test_sync_remote.sh - Unit tests for sync_scripts/sync_remote_to_local.sh
#
# These tests exercise the real script, unmodified. Two tricks make that possible:
#
#   1. The script is copied into a throwaway install dir alongside lib.sh, and
#      GDRIVE_SYNC_CONFIG points at a test config that puts every path (lockfile,
#      logfile, dirs) under /tmp. This is the same layout install.sh produces.
#   2. A fake `rclone` is placed first on PATH, so sync behavior (slow, md5 mismatch,
#      hard error, success) is scripted and deterministic. No network, no real Drive.
#
# Set GDRIVE_SYNC_SCRIPT to test a different copy of the script (used to confirm
# these tests actually catch the pre-fix flock regression).
#
# Non-interactive. Exits 0 if all tests pass, 1 otherwise.

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_UNDER_TEST="${GDRIVE_SYNC_SCRIPT:-$REPO_DIR/sync_scripts/sync_remote_to_local.sh}"

TEST_ROOT="/tmp/gdrive_sync_unit_test"
PROJ_DIR="$TEST_ROOT/install"
CONFIG_FILE="$TEST_ROOT/config.sh"
BIN_DIR="$TEST_ROOT/bin"
LOCAL_DIR="$TEST_ROOT/local"
REMOTE_DIR="$TEST_ROOT/remote"
LOCKFILE="$TEST_ROOT/gdrive_sync.lock"
LAST_CHANGE_FILE="$TEST_ROOT/gdrive_last_change"
LOGFILE="$TEST_ROOT/gdrive_sync.log"
CALLS_FILE="$TEST_ROOT/rclone_calls"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
FAILED_NAMES=()

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

print_header() {
    echo -e "\n${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}\n"
}

print_success() { echo -e "${GREEN}✓ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠ $1${NC}"; }
print_error()   { echo -e "${RED}✗ $1${NC}"; }

pass() {
    TESTS_PASSED=$((TESTS_PASSED + 1))
    print_success "$1"
}

fail() {
    TESTS_FAILED=$((TESTS_FAILED + 1))
    FAILED_NAMES+=("$CURRENT_TEST: $1")
    print_error "$1"
}

start_test() {
    CURRENT_TEST="$1"
    TESTS_RUN=$((TESTS_RUN + 1))
    echo ""
    echo -e "${BLUE}--- $CURRENT_TEST ---${NC}"
}

# ----------------------------------------------------------------------------
# Harness
# ----------------------------------------------------------------------------

build_fake_project() {
    rm -rf "$TEST_ROOT"
    mkdir -p "$PROJ_DIR" "$BIN_DIR" "$LOCAL_DIR" "$REMOTE_DIR"

    # Mirror the install layout: script and lib.sh side by side
    cp "$SCRIPT_UNDER_TEST" "$PROJ_DIR/sync_remote_to_local.sh"
    chmod +x "$PROJ_DIR/sync_remote_to_local.sh"

    if [ -f "$(dirname "$SCRIPT_UNDER_TEST")/lib.sh" ]; then
        cp "$(dirname "$SCRIPT_UNDER_TEST")/lib.sh" "$PROJ_DIR/lib.sh"
    fi

    # The sync tests need a non-empty local dir; the guard tests override this.
    echo "seed" > "$LOCAL_DIR/seed.md"

    # Test config: same variable names as the real config.sh, all paths in /tmp.
    # RETRY_DELAY=0 keeps the retry tests fast.
    cat > "$CONFIG_FILE" <<EOF
LOCAL_DIR="$LOCAL_DIR"
REMOTE_DIR="$REMOTE_DIR"
RETRY_DELAY=0
MAX_RETRIES=5
DEBOUNCE_DELAY=4
MAX_DELETE_COUNT=5
SYNC_DISABLED_FILE="$TEST_ROOT/gdrive_sync_disabled"
LOCKFILE="$LOCKFILE"
LAST_CHANGE_FILE="$LAST_CHANGE_FILE"
LOGFILE="$LOGFILE"
EOF

    build_fake_rclone
    : > "$LOGFILE"
}

# Fake rclone. Behavior comes from FAKE_RCLONE_MODE; every invocation is recorded
# in $CALLS_FILE so tests can count attempts.
build_fake_rclone() {
    cat > "$BIN_DIR/rclone" <<'EOF'
#!/bin/bash
echo "$@" >> "$FAKE_RCLONE_CALLS"
call_num=$(wc -l < "$FAKE_RCLONE_CALLS")

md5_error() {
    echo "<3>ERROR : file.md: corrupted on transfer: md5 hashes differ src(Local) 1a2b vs dst(Drive) 3c4d"
    echo "<3>ERROR : Attempt 1/3 failed with 1 errors"
}

generic_error() {
    echo "<3>ERROR : Entities: error reading source directory: couldn't list directory: googleapi: Error 403: Quota exceeded, rateLimitExceeded"
}

case "$FAKE_RCLONE_MODE" in
    slow)
        sleep "${FAKE_RCLONE_SLEEP:-3}"
        ;;
    md5_then_success)
        if [ "$call_num" -le "${FAKE_RCLONE_FAIL_COUNT:-1}" ]; then
            md5_error
            exit 1
        fi
        ;;
    md5_always)
        md5_error
        exit 1
        ;;
    error_always)
        generic_error
        exit 1
        ;;
    error_then_success)
        if [ "$call_num" -le "${FAKE_RCLONE_FAIL_COUNT:-1}" ]; then
            generic_error
            exit 1
        fi
        ;;
    noisy_success)
        # rclone recovered internally: ERROR lines on stderr, but exit 0.
        generic_error
        echo "<3>ERROR : Attempt 3/3 succeeded"
        exit 0
        ;;
esac

# success: quiet, exit 0
exit 0
EOF
    chmod +x "$BIN_DIR/rclone"
}

# Run the script under test. Extra env is inherited by the fake rclone.
# Usage: run_sync [timeout_seconds]
run_sync() {
    local tmo="${1:-30}"
    PATH="$BIN_DIR:$PATH" \
    FAKE_RCLONE_CALLS="$CALLS_FILE" \
    GDRIVE_SYNC_CONFIG="$CONFIG_FILE" \
        timeout "$tmo" "$PROJ_DIR/sync_remote_to_local.sh" \
        > "$TEST_ROOT/stdout" 2> "$TEST_ROOT/stderr"
    echo $?
}

run_sync_bg() {
    PATH="$BIN_DIR:$PATH" \
    FAKE_RCLONE_CALLS="$CALLS_FILE" \
    GDRIVE_SYNC_CONFIG="$CONFIG_FILE" \
        "$PROJ_DIR/sync_remote_to_local.sh" \
        > "$TEST_ROOT/stdout" 2> "$TEST_ROOT/stderr" &
    echo $!
}

reset_state() {
    : > "$LOGFILE"
    : > "$CALLS_FILE"
    rm -f "$LOCKFILE" "$LAST_CHANGE_FILE" "$TEST_ROOT/stdout" "$TEST_ROOT/stderr"
}

rclone_call_count() {
    [ -f "$CALLS_FILE" ] && wc -l < "$CALLS_FILE" | tr -d ' ' || echo 0
}

# True (0) if the lock is currently held by some other process.
lock_is_held() {
    [ -f "$LOCKFILE" ] || return 1
    if flock -n "$LOCKFILE" -c : 2>/dev/null; then
        return 1  # we acquired it, so nobody held it
    fi
    return 0
}

# Block until the sync has actually started rclone, so we can inspect mid-run.
wait_for_sync_start() {
    local deadline=$((SECONDS + 10))
    while [ $SECONDS -lt $deadline ]; do
        [ "$(rclone_call_count)" -ge 1 ] && return 0
        sleep 0.1
    done
    return 1
}

log_contains() { grep -q "$1" "$LOGFILE" 2>/dev/null; }

# ----------------------------------------------------------------------------
# Tests: locking (regression coverage for the flock fix)
# ----------------------------------------------------------------------------

test_clean_exit_no_flock_error() {
    start_test "Exits 0 with no flock errors on a normal sync"
    reset_state

    local rc
    rc=$(FAKE_RCLONE_MODE=success run_sync)

    if [ "$rc" -eq 0 ]; then
        pass "Exit code 0"
    else
        fail "Expected exit 0, got $rc (systemd reported status=64/USAGE for this bug)"
    fi

    if grep -q "bad file descriptor" "$TEST_ROOT/stderr"; then
        fail "stderr contains 'flock: bad file descriptor': $(cat "$TEST_ROOT/stderr")"
    else
        pass "No 'bad file descriptor' on stderr"
    fi

    if log_contains "SUCCESS: Sync completed"; then
        pass "Logged SUCCESS"
    else
        fail "Did not log SUCCESS"
    fi
}

test_lock_held_during_sync() {
    start_test "Lock is actually held for the duration of the sync"
    reset_state

    local pid
    pid=$(FAKE_RCLONE_MODE=slow FAKE_RCLONE_SLEEP=3 run_sync_bg)

    if ! wait_for_sync_start; then
        fail "Sync never invoked rclone"
        kill "$pid" 2>/dev/null
        return
    fi

    if lock_is_held; then
        pass "Lock held while rclone is running"
    else
        fail "Lock was NOT held during sync (flock -c : releases immediately)"
    fi

    wait "$pid" 2>/dev/null
}

test_lock_released_after_sync() {
    start_test "Lock is released once the sync finishes"
    reset_state

    FAKE_RCLONE_MODE=success run_sync > /dev/null

    if lock_is_held; then
        fail "Lock still held after the script exited"
    else
        pass "Lock released after completion"
    fi
}

test_concurrent_run_skipped() {
    start_test "Second concurrent run is skipped, not raced"
    reset_state

    local pid
    pid=$(FAKE_RCLONE_MODE=slow FAKE_RCLONE_SLEEP=3 run_sync_bg)

    if ! wait_for_sync_start; then
        fail "First sync never started"
        kill "$pid" 2>/dev/null
        return
    fi

    # Second invocation while the first still holds the lock
    FAKE_RCLONE_MODE=success run_sync 10 > /dev/null

    if log_contains "Another instance is already running"; then
        pass "Second run logged the skip warning"
    else
        fail "Second run did not log 'Another instance is already running'"
    fi

    wait "$pid" 2>/dev/null

    local calls
    calls=$(rclone_call_count)
    if [ "$calls" -eq 1 ]; then
        pass "rclone ran exactly once (second run skipped)"
    else
        fail "Expected 1 rclone call, got $calls (concurrent syncs both ran)"
    fi
}

# ----------------------------------------------------------------------------
# Tests: debounce against recent local changes
# ----------------------------------------------------------------------------

test_skips_on_recent_local_change() {
    start_test "Skips sync when a local change happened <10s ago"
    reset_state

    date +%s%N > "$LAST_CHANGE_FILE"

    FAKE_RCLONE_MODE=success run_sync > /dev/null

    if log_contains "Skipping remote sync due to recent local changes"; then
        pass "Logged the debounce skip"
    else
        fail "Did not log the debounce skip"
    fi

    local calls
    calls=$(rclone_call_count)
    if [ "$calls" -eq 0 ]; then
        pass "rclone was not invoked"
    else
        fail "Expected 0 rclone calls, got $calls"
    fi
}

test_syncs_after_debounce_window() {
    start_test "Syncs when the last local change is older than 10s"
    reset_state

    # 30 seconds ago, in nanoseconds
    echo $(( $(date +%s%N) - 30000000000 )) > "$LAST_CHANGE_FILE"

    FAKE_RCLONE_MODE=success run_sync > /dev/null

    if log_contains "Skipping remote sync"; then
        fail "Incorrectly skipped a sync outside the debounce window"
    else
        pass "Did not skip"
    fi

    local calls
    calls=$(rclone_call_count)
    if [ "$calls" -eq 1 ]; then
        pass "rclone invoked once"
    else
        fail "Expected 1 rclone call, got $calls"
    fi
}

test_syncs_when_no_change_file() {
    start_test "Syncs normally when no last-change file exists"
    reset_state
    rm -f "$LAST_CHANGE_FILE"

    FAKE_RCLONE_MODE=success run_sync > /dev/null

    if [ "$(rclone_call_count)" -eq 1 ]; then
        pass "rclone invoked once"
    else
        fail "Expected 1 rclone call, got $(rclone_call_count)"
    fi
}

# ----------------------------------------------------------------------------
# Tests: md5 retry loop
# ----------------------------------------------------------------------------

test_md5_mismatch_retries_then_succeeds() {
    start_test "Retries on md5 mismatch and succeeds"
    reset_state

    FAKE_RCLONE_MODE=md5_then_success FAKE_RCLONE_FAIL_COUNT=2 run_sync > /dev/null

    if log_contains "MD5 mismatch detected (attempt 1/5)"; then
        pass "Logged first retry attempt"
    else
        fail "Did not log 'MD5 mismatch detected (attempt 1/5)'"
    fi

    if log_contains "SUCCESS: Sync completed"; then
        pass "Eventually logged SUCCESS"
    else
        fail "Never logged SUCCESS"
    fi

    local calls
    calls=$(rclone_call_count)
    if [ "$calls" -eq 3 ]; then
        pass "rclone called 3 times (2 failures + 1 success)"
    else
        fail "Expected 3 rclone calls, got $calls"
    fi
}

test_md5_mismatch_gives_up_at_max_retries() {
    start_test "Gives up after MAX_RETRIES on persistent md5 mismatch"
    reset_state

    local rc
    rc=$(FAKE_RCLONE_MODE=md5_always run_sync 20)

    if [ "$rc" -eq 124 ]; then
        fail "Script timed out - retry loop did not terminate"
        return
    fi

    local calls
    calls=$(rclone_call_count)
    if [ "$calls" -eq 5 ]; then
        pass "Bounded at exactly MAX_RETRIES (5) rclone calls"
    else
        fail "Expected 5 rclone calls, got $calls"
    fi

    if log_contains "ERROR: Sync failed after 5 attempts"; then
        pass "Logged final failure"
    else
        fail "Did not log 'ERROR: Sync failed after 5 attempts'"
    fi
}

# ----------------------------------------------------------------------------
# Tests: non-md5 error handling
# ----------------------------------------------------------------------------

test_transient_error_retries_then_succeeds() {
    start_test "Retries a transient non-md5 error, then succeeds"
    reset_state

    FAKE_RCLONE_MODE=error_then_success FAKE_RCLONE_FAIL_COUNT=1 run_sync 20 > /dev/null

    if log_contains "WARNING: Sync error, rclone exit 1 (attempt 1/5)"; then
        pass "Counted the failure as attempt 1/5"
    else
        fail "Did not log 'WARNING: Sync error, rclone exit 1 (attempt 1/5)'"
    fi

    if log_contains "SUCCESS: Sync completed"; then
        pass "Recovered and logged SUCCESS"
    else
        fail "Never logged SUCCESS"
    fi

    local calls
    calls=$(rclone_call_count)
    if [ "$calls" -eq 2 ]; then
        pass "rclone called twice (1 failure + 1 success)"
    else
        fail "Expected 2 rclone calls, got $calls"
    fi
}

test_generic_error_retry_is_bounded() {
    start_test "Persistent non-md5 error does not retry forever"
    reset_state

    local rc
    rc=$(FAKE_RCLONE_MODE=error_always run_sync 8)

    local calls
    calls=$(rclone_call_count)

    if [ "$rc" -eq 124 ]; then
        fail "Script had to be killed at 8s - retry loop never exits ($calls rclone calls)"
        return
    fi

    if [ "$calls" -eq 5 ]; then
        pass "Bounded at exactly MAX_RETRIES (5) rclone calls"
    else
        fail "Ran $calls rclone calls for a persistent error (expected 5)"
    fi

    if log_contains "rateLimitExceeded"; then
        pass "Logged the underlying rclone output"
    else
        fail "Did not log the rclone error output"
    fi
}

test_noisy_success_is_not_a_failure() {
    start_test "rclone exit 0 with ERROR lines in output counts as success"
    reset_state

    FAKE_RCLONE_MODE=noisy_success run_sync > /dev/null

    if log_contains "SUCCESS: Sync completed"; then
        pass "Classified as SUCCESS via exit code"
    else
        fail "Did not log SUCCESS (output-grepping misreads rclone's internal retries)"
    fi

    if log_contains "ERROR: Sync failed"; then
        fail "Logged a spurious 'Sync failed' for a successful run"
    else
        pass "No spurious failure logged"
    fi

    local calls
    calls=$(rclone_call_count)
    if [ "$calls" -eq 1 ]; then
        pass "Did not retry a successful sync"
    else
        fail "Expected 1 rclone call, got $calls (retried a successful sync)"
    fi
}

# ----------------------------------------------------------------------------
# Tests: config guards
# ----------------------------------------------------------------------------

test_refuses_when_local_dir_missing() {
    start_test "Refuses to sync when LOCAL_DIR does not exist"
    reset_state

    local saved="$LOCAL_DIR.saved"
    mv "$LOCAL_DIR" "$saved"

    FAKE_RCLONE_MODE=success run_sync > /dev/null

    if log_contains "ERROR: LOCAL_DIR does not exist"; then
        pass "Logged the refusal"
    else
        fail "Did not log 'ERROR: LOCAL_DIR does not exist'"
    fi

    local calls
    calls=$(rclone_call_count)
    if [ "$calls" -eq 0 ]; then
        pass "rclone was not invoked (no mirror into the wrong path)"
    else
        fail "Expected 0 rclone calls, got $calls"
    fi

    if [ -d "$LOCAL_DIR" ]; then
        fail "LOCAL_DIR was created despite the guard"
    else
        pass "Did not create the missing directory"
    fi

    mv "$saved" "$LOCAL_DIR"
}

test_allows_empty_local_dir_on_pull() {
    start_test "Allows an empty LOCAL_DIR when pulling (first-run install)"
    reset_state

    local saved
    saved=$(mktemp -d)
    mv "$LOCAL_DIR"/* "$saved"/ 2>/dev/null

    FAKE_RCLONE_MODE=success run_sync > /dev/null

    if [ "$(rclone_call_count)" -eq 1 ]; then
        pass "Pull proceeded into the empty directory"
    else
        fail "Expected 1 rclone call, got $(rclone_call_count)"
    fi

    mv "$saved"/* "$LOCAL_DIR"/ 2>/dev/null
    rmdir "$saved"
}

test_missing_config_is_fatal() {
    start_test "Exits with a clear error when config.sh is missing"
    reset_state

    mv "$CONFIG_FILE" "$CONFIG_FILE.saved"

    local rc
    rc=$(FAKE_RCLONE_MODE=success run_sync)

    if [ "$rc" -ne 0 ]; then
        pass "Exited non-zero ($rc)"
    else
        fail "Expected non-zero exit, got 0"
    fi

    if grep -q "no config at" "$TEST_ROOT/stderr"; then
        pass "Explained the problem on stderr"
    else
        fail "stderr lacked a clear message: $(cat "$TEST_ROOT/stderr")"
    fi

    if [ "$(rclone_call_count)" -eq 0 ]; then
        pass "rclone was not invoked"
    else
        fail "Expected 0 rclone calls, got $(rclone_call_count)"
    fi

    mv "$CONFIG_FILE.saved" "$CONFIG_FILE"
}

test_defaults_applied_for_missing_settings() {
    start_test "Applies defaults when optional settings are absent"
    reset_state

    # A config predating MAX_RETRIES/MAX_DELETE_COUNT, as an older install would have
    cp "$CONFIG_FILE" "$CONFIG_FILE.saved"
    cat > "$CONFIG_FILE" <<EOF
LOCAL_DIR="$LOCAL_DIR"
REMOTE_DIR="$REMOTE_DIR"
RETRY_DELAY=0
LOCKFILE="$LOCKFILE"
LAST_CHANGE_FILE="$LAST_CHANGE_FILE"
LOGFILE="$LOGFILE"
EOF

    FAKE_RCLONE_MODE=error_always run_sync 20 > /dev/null

    local calls
    calls=$(rclone_call_count)
    if [ "$calls" -eq 5 ]; then
        pass "MAX_RETRIES defaulted to 5 (bounded at $calls calls)"
    else
        fail "Expected 5 rclone calls from the default, got $calls"
    fi

    mv "$CONFIG_FILE.saved" "$CONFIG_FILE"
}

# ----------------------------------------------------------------------------
# Runner
# ----------------------------------------------------------------------------

main() {
    print_header "sync_remote_to_local.sh Unit Tests"
    echo "Script under test: $SCRIPT_UNDER_TEST"
    echo "Sandbox:           $TEST_ROOT"
    echo "No network or real Google Drive access is used."

    if [ ! -f "$SCRIPT_UNDER_TEST" ]; then
        print_error "Script not found: $SCRIPT_UNDER_TEST"
        exit 1
    fi

    build_fake_project

    print_header "Locking"
    test_clean_exit_no_flock_error
    test_lock_held_during_sync
    test_lock_released_after_sync
    test_concurrent_run_skipped

    print_header "Debounce"
    test_skips_on_recent_local_change
    test_syncs_after_debounce_window
    test_syncs_when_no_change_file

    print_header "Retry on md5 mismatch"
    test_md5_mismatch_retries_then_succeeds
    test_md5_mismatch_gives_up_at_max_retries

    print_header "Non-md5 errors"
    test_transient_error_retries_then_succeeds
    test_generic_error_retry_is_bounded
    test_noisy_success_is_not_a_failure

    print_header "Config guards"
    test_refuses_when_local_dir_missing
    test_allows_empty_local_dir_on_pull
    test_missing_config_is_fatal
    test_defaults_applied_for_missing_settings

    print_header "Summary"
    echo "Test groups run: $TESTS_RUN"
    echo "Assertions passed: $TESTS_PASSED"
    echo "Assertions failed: $TESTS_FAILED"

    if [ "$TESTS_FAILED" -gt 0 ]; then
        echo ""
        print_error "Failures:"
        for name in "${FAILED_NAMES[@]}"; do
            echo "  • $name"
        done
        echo ""
        rm -rf "$TEST_ROOT"
        exit 1
    fi

    echo ""
    print_success "All tests passed"
    rm -rf "$TEST_ROOT"
    exit 0
}

main
