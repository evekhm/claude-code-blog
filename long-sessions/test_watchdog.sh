#!/usr/bin/env bash
# ============================================================================
# End-to-end test for the watchdog + orchestrator
# ============================================================================
#
# Uses a mock "claude" binary — no API calls, no cost.
#
# Scenario:
#   - Phase 1: succeeds
#   - Phase 2: FAILS on first attempt (orchestrator crashes)
#   - Watchdog detects, restarts from phase 2
#   - Phase 2: succeeds on retry
#   - Phase 3: succeeds
#   - Retro: succeeds
#
# Usage:
#   ./test_watchdog.sh
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$(mktemp -d)"
MOCK_BIN="$TEST_DIR/mock_bin"
FAIL_FLAG="$TEST_DIR/.phase2_failed_once"

echo "=== Watchdog End-to-End Test ==="
echo "Test dir: $TEST_DIR"
echo ""

# ---- Create mock claude binary ----
mkdir -p "$MOCK_BIN"
cat > "$MOCK_BIN/claude" <<MOCK
#!/usr/bin/env bash
# Mock claude: fails on Phase 2 first attempt, succeeds otherwise
# Ignores all flags (--print, --model, etc.), just reads the prompt (last arg)

PROMPT="\${*: -1}"
FAIL_FLAG="$FAIL_FLAG"

# Simulate some work
sleep 2

if echo "\$PROMPT" | grep -q "Phase 2" && [ ! -f "\$FAIL_FLAG" ]; then
    touch "\$FAIL_FLAG"
    echo "Mock Claude: Starting Phase 2..."
    echo "Mock Claude: ERROR — simulated crash (e.g., API timeout)"
    exit 1
fi

if echo "\$PROMPT" | grep -q "retro"; then
    echo "Mock Claude: Writing retrospective..."
    # Find run dir from prompt
    RUN_DIR=\$(echo "\$PROMPT" | grep -oP 'Run directory: \K\S+')
    if [ -n "\$RUN_DIR" ]; then
        echo "# Session Retrospective" > "\$RUN_DIR/session_retro.md"
        echo "All phases completed successfully." >> "\$RUN_DIR/session_retro.md"
    fi
    exit 0
fi

echo "Mock Claude: Processing phase..."
echo "Mock Claude: Task completed successfully."
exit 0
MOCK
chmod +x "$MOCK_BIN/claude"

# ---- Put mock claude first in PATH ----
export PATH="$MOCK_BIN:$PATH"

# Verify mock is being used
WHICH_CLAUDE="$(which claude)"
echo "Using claude: $WHICH_CLAUDE"
if [[ "$WHICH_CLAUDE" != "$MOCK_BIN/claude" ]]; then
    echo "ERROR: Mock claude not on PATH correctly"
    exit 1
fi

# ---- Create a STATUS.md for the test ----
cat > "$SCRIPT_DIR/STATUS.md" <<'STATUS'
# Project Status
**State**: Ready to start
## What's Next
- [ ] Phase 1: Setup
- [ ] Phase 2: Execute
- [ ] Phase 3: Summarize
STATUS

# ---- Launch orchestrator (it will crash on phase 2) ----
echo ""
echo "--- Launching orchestrator (phases 1-3) ---"
echo "Expected: phase 1 succeeds, phase 2 fails, orchestrator exits"
echo ""

# Run in background so watchdog can monitor it
nohup "$SCRIPT_DIR/run_autonomous.sh" \
    --budget 0.50 \
    < /dev/null \
    > /dev/null 2>&1 &
ORCH_PID=$!
echo "Orchestrator PID: $ORCH_PID"

# Give orchestrator a moment to create its run directory
sleep 3

# Find the run directory it created
RUN_DIR=$(ls -td "$SCRIPT_DIR/runs/"*/ 2>/dev/null | head -1)
if [ -z "$RUN_DIR" ]; then
    echo "ERROR: No run directory created"
    kill $ORCH_PID 2>/dev/null || true
    exit 1
fi
RUN_DIR="${RUN_DIR%/}"  # strip trailing slash
echo "Run directory: $RUN_DIR"

# ---- Launch watchdog ----
echo ""
echo "--- Launching watchdog ---"
nohup "$SCRIPT_DIR/watchdog.sh" "$RUN_DIR" "$ORCH_PID" \
    < /dev/null \
    > /dev/null 2>&1 &
WATCHDOG_PID=$!
echo "Watchdog PID: $WATCHDOG_PID"

# ---- Wait and monitor ----
echo ""
echo "--- Monitoring (checking every 15s, timeout 5min) ---"
TIMEOUT=300
ELAPSED=0

while [ $ELAPSED -lt $TIMEOUT ]; do
    sleep 15
    ELAPSED=$((ELAPSED + 15))

    # Check what's completed
    PHASES_DONE=""
    for i in 1 2 3; do
        if [ -f "$RUN_DIR/.phase_${i}_done" ]; then
            PHASES_DONE="${PHASES_DONE} $i"
        fi
    done

    HAS_RETRO="no"
    if [ -f "$RUN_DIR/session_retro.md" ]; then
        HAS_RETRO="yes"
    fi

    echo "[${ELAPSED}s] Phases done:${PHASES_DONE:-none} | Retro: $HAS_RETRO"

    # Check if watchdog is still running
    if ! kill -0 $WATCHDOG_PID 2>/dev/null; then
        echo ""
        echo "Watchdog exited — checking results..."
        break
    fi

    # All done?
    if [ -f "$RUN_DIR/.phase_3_done" ] && [ -f "$RUN_DIR/session_retro.md" ]; then
        echo ""
        echo "All phases + retro complete!"
        break
    fi
done

# ---- Check results ----
echo ""
echo "=== RESULTS ==="
echo ""

PASS=true

# Phase 1 should have completed
if [ -f "$RUN_DIR/.phase_1_done" ]; then
    echo "PASS: Phase 1 completed"
else
    echo "FAIL: Phase 1 did not complete"
    PASS=false
fi

# Phase 2 should have failed once then succeeded
if [ -f "$FAIL_FLAG" ]; then
    echo "PASS: Phase 2 failed on first attempt (flag exists)"
else
    echo "FAIL: Phase 2 never failed (mock didn't trigger)"
    PASS=false
fi

if [ -f "$RUN_DIR/.phase_2_done" ]; then
    echo "PASS: Phase 2 completed on retry"
else
    echo "FAIL: Phase 2 never completed"
    PASS=false
fi

# Phase 3 should have completed
if [ -f "$RUN_DIR/.phase_3_done" ]; then
    echo "PASS: Phase 3 completed"
else
    echo "FAIL: Phase 3 did not complete"
    PASS=false
fi

# Retro should exist
if [ -f "$RUN_DIR/session_retro.md" ]; then
    echo "PASS: Retrospective written"
else
    echo "FAIL: No retrospective file"
    PASS=false
fi

# Watchdog log should show restart
if [ -f "$RUN_DIR/watchdog.log" ]; then
    if grep -q "ALERT" "$RUN_DIR/watchdog.log"; then
        echo "PASS: Watchdog detected failure"
    else
        echo "FAIL: Watchdog log has no ALERT"
        PASS=false
    fi
    if grep -q "Restarted" "$RUN_DIR/watchdog.log"; then
        echo "PASS: Watchdog restarted orchestrator"
    else
        echo "FAIL: Watchdog did not restart"
        PASS=false
    fi
    echo ""
    echo "--- Watchdog log ---"
    cat "$RUN_DIR/watchdog.log"
else
    echo "FAIL: No watchdog log"
    PASS=false
fi

# ---- Cleanup ----
echo ""
kill $WATCHDOG_PID 2>/dev/null || true
kill $ORCH_PID 2>/dev/null || true
rm -f "$SCRIPT_DIR/STATUS.md"
rm -f "$FAIL_FLAG"
# Leave run dir for inspection

echo ""
if $PASS; then
    echo "=== ALL TESTS PASSED ==="
else
    echo "=== SOME TESTS FAILED ==="
    echo "Inspect: $RUN_DIR"
    echo "Master log: $RUN_DIR/master.log"
fi
