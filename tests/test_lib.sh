#!/bin/bash
# test_lib.sh - Unit tests for sync_scripts/lib.sh
#
# Tests the config loading, defaults, and safety guards directly, without
# running a full sync. This is the only place the local-to-remote "empty vault"
# guard can be exercised cheaply, since that script is a long-running daemon.
#
# Non-interactive. Exits 0 if all tests pass, 1 otherwise.

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$REPO_DIR/sync_scripts/lib.sh"

TEST_ROOT="/tmp/gdrive_sync_lib_test"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
FAILED_NAMES=()

GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

print_header() {
    echo -e "\n${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}\n"
}

pass() { TESTS_PASSED=$((TESTS_PASSED + 1)); echo -e "${GREEN}✓ $1${NC}"; }
fail() {
    TESTS_FAILED=$((TESTS_FAILED + 1))
    FAILED_NAMES+=("$CURRENT_TEST: $1")
    echo -e "${RED}✗ $1${NC}"
}

start_test() {
    CURRENT_TEST="$1"
    TESTS_RUN=$((TESTS_RUN + 1))
    echo ""
    echo -e "${BLUE}--- $CURRENT_TEST ---${NC}"
}

# lib.sh logs through generate_prefix(), which the sourcing script provides.
generate_prefix() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') | TEST |"
}

setup() {
    rm -rf "$TEST_ROOT"
    mkdir -p "$TEST_ROOT/proj" "$TEST_ROOT/vault"
    LOGFILE="$TEST_ROOT/test.log"
    : > "$LOGFILE"
}

write_config() {
    cat > "$TEST_ROOT/proj/config.sh"
}

# Run load_config in a subshell so defaults don't leak between tests.
# Prints "rc=<code>" followed by any requested variable values.
load_in_subshell() {
    local want="$1"
    (
        source "$LIB"
        load_config "$TEST_ROOT/proj" 2> "$TEST_ROOT/stderr"
        echo "rc=$?"
        [ -n "$want" ] && eval "echo \"\$$want\""
    )
}

# ----------------------------------------------------------------------------

test_missing_config() {
    start_test "load_config fails when config.sh is absent"
    setup

    local out
    out=$(load_in_subshell "")

    if [[ "$out" == *"rc=1"* ]]; then
        pass "Returned non-zero"
    else
        fail "Expected rc=1, got: $out"
    fi

    if grep -q "no config at" "$TEST_ROOT/stderr"; then
        pass "Explained the problem on stderr"
    else
        fail "stderr lacked a clear message"
    fi
}

test_missing_local_dir_var() {
    start_test "load_config fails when LOCAL_DIR is unset"
    setup
    write_config <<EOF
REMOTE_DIR="remote:folder"
EOF

    local out
    out=$(load_in_subshell "")

    if [[ "$out" == *"rc=1"* ]]; then
        pass "Returned non-zero"
    else
        fail "Expected rc=1, got: $out"
    fi

    if grep -q "LOCAL_DIR is not set" "$TEST_ROOT/stderr"; then
        pass "Named the missing setting"
    else
        fail "stderr did not name LOCAL_DIR"
    fi
}

test_missing_remote_dir_var() {
    start_test "load_config fails when REMOTE_DIR is unset"
    setup
    write_config <<EOF
LOCAL_DIR="$TEST_ROOT/vault"
EOF

    local out
    out=$(load_in_subshell "")

    if [[ "$out" == *"rc=1"* ]]; then
        pass "Returned non-zero"
    else
        fail "Expected rc=1, got: $out"
    fi

    if grep -q "REMOTE_DIR is not set" "$TEST_ROOT/stderr"; then
        pass "Named the missing setting"
    else
        fail "stderr did not name REMOTE_DIR"
    fi
}

test_defaults_applied() {
    start_test "load_config defaults the optional settings"
    setup
    write_config <<EOF
LOCAL_DIR="$TEST_ROOT/vault"
REMOTE_DIR="remote:folder"
EOF

    local out
    out=$(load_in_subshell "MAX_DELETE_COUNT")

    if [[ "$out" == *"rc=0"* ]]; then
        pass "Returned success"
    else
        fail "Expected rc=0, got: $out"
    fi

    # This is the fail-open case: with MAX_DELETE_COUNT empty, the delete guard
    # errors and evaluates false, letting an unbounded delete through.
    local value
    value=$(echo "$out" | tail -1)
    if [ "$value" = "5" ]; then
        pass "MAX_DELETE_COUNT defaulted to 5"
    else
        fail "Expected MAX_DELETE_COUNT=5, got '$value'"
    fi
}

test_config_values_win_over_defaults() {
    start_test "Explicit config values are not overridden by defaults"
    setup
    write_config <<EOF
LOCAL_DIR="$TEST_ROOT/vault"
REMOTE_DIR="remote:folder"
MAX_DELETE_COUNT=99
EOF

    local value
    value=$(load_in_subshell "MAX_DELETE_COUNT" | tail -1)

    if [ "$value" = "99" ]; then
        pass "Kept the configured value (99)"
    else
        fail "Expected 99, got '$value'"
    fi
}

test_require_local_dir_missing() {
    start_test "require_local_dir rejects a path that does not exist"
    setup
    source "$LIB"
    LOCAL_DIR="$TEST_ROOT/does_not_exist"

    if require_local_dir; then
        fail "Accepted a nonexistent directory"
    else
        pass "Rejected it"
    fi

    if grep -q "ERROR: LOCAL_DIR does not exist" "$LOGFILE"; then
        pass "Logged the reason"
    else
        fail "Nothing logged"
    fi
}

test_require_local_dir_present() {
    start_test "require_local_dir accepts an existing path"
    setup
    source "$LIB"
    LOCAL_DIR="$TEST_ROOT/vault"

    if require_local_dir; then
        pass "Accepted it"
    else
        fail "Rejected an existing directory"
    fi
}

test_require_not_empty_rejects_empty() {
    start_test "require_local_dir_not_empty rejects an empty vault"
    setup
    source "$LIB"
    LOCAL_DIR="$TEST_ROOT/vault"

    if require_local_dir_not_empty; then
        fail "Accepted an empty vault (this would wipe the remote)"
    else
        pass "Rejected it"
    fi

    if grep -q "ERROR: LOCAL_DIR is empty" "$LOGFILE"; then
        pass "Logged the reason"
    else
        fail "Nothing logged"
    fi
}

test_require_not_empty_accepts_files() {
    start_test "require_local_dir_not_empty accepts a populated vault"
    setup
    source "$LIB"
    LOCAL_DIR="$TEST_ROOT/vault"
    echo "note" > "$LOCAL_DIR/note.md"

    if require_local_dir_not_empty; then
        pass "Accepted it"
    else
        fail "Rejected a populated vault"
    fi
}

test_require_not_empty_counts_hidden_files() {
    start_test "require_local_dir_not_empty counts hidden entries (.obsidian)"
    setup
    source "$LIB"
    LOCAL_DIR="$TEST_ROOT/vault"
    mkdir -p "$LOCAL_DIR/.obsidian"

    if require_local_dir_not_empty; then
        pass "A vault holding only .obsidian is not 'empty'"
    else
        fail "Treated a hidden-only directory as empty"
    fi
}

# ----------------------------------------------------------------------------

main() {
    print_header "lib.sh Unit Tests"
    echo "Library under test: $LIB"

    if [ ! -f "$LIB" ]; then
        echo "Library not found: $LIB"
        exit 1
    fi

    print_header "Config loading"
    test_missing_config
    test_missing_local_dir_var
    test_missing_remote_dir_var
    test_defaults_applied
    test_config_values_win_over_defaults

    print_header "LOCAL_DIR guards"
    test_require_local_dir_missing
    test_require_local_dir_present
    test_require_not_empty_rejects_empty
    test_require_not_empty_accepts_files
    test_require_not_empty_counts_hidden_files

    print_header "Summary"
    echo "Test groups run: $TESTS_RUN"
    echo "Assertions passed: $TESTS_PASSED"
    echo "Assertions failed: $TESTS_FAILED"

    if [ "$TESTS_FAILED" -gt 0 ]; then
        echo ""
        echo -e "${RED}Failures:${NC}"
        for name in "${FAILED_NAMES[@]}"; do
            echo "  • $name"
        done
        rm -rf "$TEST_ROOT"
        exit 1
    fi

    echo ""
    echo -e "${GREEN}✓ All tests passed${NC}"
    rm -rf "$TEST_ROOT"
    exit 0
}

main
