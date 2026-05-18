#!/usr/bin/env bash
# ============================================================================
# End-to-end test: Orchestrator + Watchdog + Claude Diagnostic
# ============================================================================
#
# Tests the full autonomous pipeline with a deliberate bug that Claude
# must diagnose and fix.
#
# Scenario:
#   Phase 1: Create sample data (succeeds)
#   Phase 2: Run a buggy Python script (fails — NameError)
#   Watchdog: Detects failure, retries, fails again, runs Claude diagnostic
#   Claude diagnostic: Reads error log, fixes the Python script
#   Phase 2 retry: Succeeds (bug is fixed)
#   Phase 3: Summarize results (succeeds)
#
# Cost: ~$1-3 (uses sonnet for all sessions)
# Duration: ~5-8 minutes (mostly watchdog check intervals)
#
# Usage:
#   ./test_e2e.sh              # Run full test
#   ./test_e2e.sh --phase 2    # Resume from phase 2 (used by watchdog)
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- Defaults ----
START_PHASE=1
END_PHASE=3
MODEL="sonnet"
MAX_BUDGET="2.00"
RUN_DIR_OVERRIDE=""
IS_INITIAL_LAUNCH=true

# ---- Parse arguments ----
while [[ $# -gt 0 ]]; do
    case "$1" in
        --phase)         START_PHASE="$2"; IS_INITIAL_LAUNCH=false; shift 2 ;;
        --until)         END_PHASE="$2"; shift 2 ;;
        --run-dir)       RUN_DIR_OVERRIDE="$2"; IS_INITIAL_LAUNCH=false; shift 2 ;;
        --model)         MODEL="$2"; shift 2 ;;
        --budget)        MAX_BUDGET="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# ---- Run directory ----
if [ -n "$RUN_DIR_OVERRIDE" ]; then
    RUN_DIR="$RUN_DIR_OVERRIDE"
else
    RUN_DIR="$SCRIPT_DIR/runs/test_$(date +%Y%m%d_%H%M%S)"
fi
mkdir -p "$RUN_DIR"

MASTER_LOG="$RUN_DIR/master.log"

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg" | tee -a "$MASTER_LOG"
}

# ---- Context management rules ----
CONTEXT_RULES='
RULES FOR THIS SESSION:
- Redirect ALL command output to log files. Only tail summaries:
    command > some.log 2>&1
    tail -20 some.log
- Keep responses SHORT. No recaps.
'

# ============================================================================
# INITIAL SETUP — only on first launch, not on watchdog restarts
# ============================================================================

if $IS_INITIAL_LAUNCH; then
    log "=============================================="
    log "E2E TEST: Orchestrator + Watchdog + Diagnostic"
    log "=============================================="
    log "Run directory: $RUN_DIR"
    log ""

    # Create the buggy Python script
    cat > "$RUN_DIR/analyze.py" <<'PYTHON'
import json
import sys

def analyze(data_file):
    with open(data_file) as f:
        data = json.load(f)

    total = sum(item['value'] for item in data)
    average = total / len(data)

    # Bug: 'counnt' is not defined (should be len(data))
    return {"total": total, "average": average, "count": counnt}

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python analyze.py <data.json>")
        sys.exit(1)
    result = analyze(sys.argv[1])
    print(json.dumps(result, indent=2))
PYTHON
    log "Created buggy analyze.py (has NameError: 'counnt')"

    # Create STATUS.md
    cat > "$SCRIPT_DIR/STATUS.md" <<'STATUS'
# Test Pipeline Status
**State**: Ready to start

## What's Next
- [ ] Phase 1: Create test data
- [ ] Phase 2: Run analysis script
- [ ] Phase 3: Summarize results
STATUS
    log "Created STATUS.md"

    # Launch watchdog (30s interval for fast testing)
    log "Launching watchdog (30s interval)..."
    WATCHDOG_INTERVAL=30 nohup "$SCRIPT_DIR/watchdog.sh" \
        "$RUN_DIR" "$$" "$SCRIPT_DIR/test_e2e.sh" \
        < /dev/null \
        > /dev/null 2>&1 &
    WATCHDOG_PID=$!
    log "Watchdog PID: $WATCHDOG_PID"
    echo "$WATCHDOG_PID" > "$RUN_DIR/.watchdog_pid"
fi

# ============================================================================
# PHASE PROMPTS
# ============================================================================

phase_prompt() {
    local phase="$1"
    local run_dir="$2"

    case "$phase" in
        1)
cat <<PROMPT
You are running Phase 1 of a test pipeline.

Run directory: $run_dir

TASK:
Create a file $run_dir/data.json with this exact content:
[
  {"name": "alpha", "value": 10},
  {"name": "beta", "value": 20},
  {"name": "charlie", "value": 30}
]

Then update STATUS.md to mark Phase 1 as done.
That's it. Do nothing else.

$CONTEXT_RULES
PROMPT
            ;;
        2)
cat <<PROMPT
You are running Phase 2 of a test pipeline.

Run directory: $run_dir

The analysis script has already been run. The output is at:
  $run_dir/results.txt

TASK:
1. Read $run_dir/results.txt and verify it contains valid JSON with total, average, count
2. Update STATUS.md to mark Phase 2 as done

$CONTEXT_RULES
PROMPT
            ;;
        3)
cat <<PROMPT
You are running Phase 3 of a test pipeline.

Run directory: $run_dir

TASK:
1. Read $run_dir/results.txt
2. Write a one-sentence summary to $run_dir/summary.txt
3. Update STATUS.md to mark Phase 3 as done and the pipeline as complete.

$CONTEXT_RULES
PROMPT
            ;;
        retro)
cat <<PROMPT
You just finished a test pipeline. Write a brief retrospective.

Run directory: $run_dir
Phase logs: $run_dir/phase_1.log through phase_${END_PHASE}.log

Write $run_dir/session_retro.md covering:
1. Which phases succeeded/failed
2. Whether the diagnostic fixed anything
3. One paragraph, keep it short

$CONTEXT_RULES
PROMPT
            ;;
        *)
            echo "ERROR: Unknown phase $phase" >&2
            return 1
            ;;
    esac
}

# ============================================================================
# Main loop
# ============================================================================

log "Starting phases $START_PHASE → $END_PHASE"

for phase in $(seq "$START_PHASE" "$END_PHASE"); do
    log "--- Phase $phase ---"

    PROMPT="$(phase_prompt "$phase" "$RUN_DIR")"
    PHASE_LOG="$RUN_DIR/phase_${phase}.log"

    log "Running phase $phase..."

    # Phase 2 pre-step: run the analysis script directly (not through Claude)
    # If it fails, the orchestrator exits and the watchdog handles recovery
    if [ "$phase" -eq 2 ]; then
        log "Phase 2 pre-step: running analyze.py..."
        set +e
        python3 "$RUN_DIR/analyze.py" "$RUN_DIR/data.json" > "$RUN_DIR/results.txt" 2>&1
        SCRIPT_EXIT=$?
        set -e
        if [ $SCRIPT_EXIT -ne 0 ]; then
            log "ERROR: analyze.py failed (exit code: $SCRIPT_EXIT)"
            log "Output: $(cat "$RUN_DIR/results.txt")"
            # Write the error to the phase log so the diagnostic can read it
            {
                echo "Phase 2 failed: analyze.py crashed"
                echo ""
                echo "Command: python3 $RUN_DIR/analyze.py $RUN_DIR/data.json"
                echo "Exit code: $SCRIPT_EXIT"
                echo ""
                echo "Error output:"
                cat "$RUN_DIR/results.txt"
                echo ""
                echo "Script location: $RUN_DIR/analyze.py"
                echo "Script contents:"
                cat "$RUN_DIR/analyze.py"
            } > "$PHASE_LOG"
            exit 1
        fi
        log "Phase 2 pre-step: analyze.py succeeded"
    fi

    set +e
    claude \
        --print \
        --dangerously-skip-permissions \
        --model "$MODEL" \
        --max-budget-usd "$MAX_BUDGET" \
        "$PROMPT" \
        < /dev/null \
        > "$PHASE_LOG" 2>&1
    EXIT_CODE=$?
    set -e

    log "Phase $phase exit code: $EXIT_CODE"
    log "Log size: $(du -h "$PHASE_LOG" 2>/dev/null | cut -f1)"
    tail -5 "$PHASE_LOG" 2>/dev/null | while IFS= read -r line; do
        log "  $line"
    done

    if [ $EXIT_CODE -ne 0 ]; then
        log "ERROR: Phase $phase failed — stopping for watchdog to handle"
        exit 1
    fi

    # Mark phase as successfully completed
    touch "$RUN_DIR/.phase_${phase}_done"
    log "Phase $phase DONE"

    sleep 2
done

# ---- Retrospective ----
log "--- Retrospective ---"
RETRO_LOG="$RUN_DIR/phase_retro.log"

set +e
claude \
    --print \
    --dangerously-skip-permissions \
    --model "$MODEL" \
    --max-budget-usd "$MAX_BUDGET" \
    "$(phase_prompt "retro" "$RUN_DIR")" \
    < /dev/null \
    > "$RETRO_LOG" 2>&1
set -e

if [ -f "$RUN_DIR/session_retro.md" ]; then
    log "Retrospective written: $RUN_DIR/session_retro.md"
else
    log "WARNING: No retrospective file"
fi

log "=============================================="
log "TEST COMPLETE. Results: $RUN_DIR"
log "=============================================="
