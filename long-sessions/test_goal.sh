#!/usr/bin/env bash
# ============================================================================
# Test: /goal mode — Claude self-heals within a phase
# ============================================================================
#
# Same buggy script as test_e2e.sh, but instead of the watchdog detecting
# the crash and launching a diagnostic, /goal keeps Claude working within
# the phase until the condition is met. Claude runs the script, sees the
# NameError, fixes it, and retries — all in one phase, no watchdog needed.
#
# This tests the /goal integration in the orchestrator.
#
# Cost: ~$0.50-1 (uses Sonnet, fewer sessions than watchdog test)
# Duration: ~2-3 minutes
#
# Usage:
#   ./test_goal.sh
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- Defaults ----
START_PHASE=1
END_PHASE=3
MODEL="sonnet"
MAX_BUDGET="3.00"
RUN_DIR_OVERRIDE=""
IS_INITIAL_LAUNCH=true

# ---- Parse arguments ----
while [[ $# -gt 0 ]]; do
    case "$1" in
        --phase)    START_PHASE="$2"; IS_INITIAL_LAUNCH=false; shift 2 ;;
        --until)    END_PHASE="$2"; shift 2 ;;
        --run-dir)  RUN_DIR_OVERRIDE="$2"; IS_INITIAL_LAUNCH=false; shift 2 ;;
        --model)    MODEL="$2"; shift 2 ;;
        --budget)   MAX_BUDGET="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# ---- Run directory ----
if [ -n "$RUN_DIR_OVERRIDE" ]; then
    RUN_DIR="$RUN_DIR_OVERRIDE"
else
    RUN_DIR="$SCRIPT_DIR/runs/goal_$(date +%Y%m%d_%H%M%S)"
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
# INITIAL SETUP
# ============================================================================

if $IS_INITIAL_LAUNCH; then
    log "=============================================="
    log "GOAL TEST: /goal self-healing phases"
    log "=============================================="
    log "Run directory: $RUN_DIR"
    log ""

    # Create the buggy Python script (same bug as test_e2e.sh)
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
fi

# ============================================================================
# PHASE PROMPTS — using /goal for self-healing
# ============================================================================

phase_prompt() {
    local phase="$1"
    local run_dir="$2"

    case "$phase" in
        1)
cat <<PROMPT
/goal Create $run_dir/data.json with this content: [{"name": "alpha", "value": 10}, {"name": "beta", "value": 20}, {"name": "charlie", "value": 30}]. Update STATUS.md to mark Phase 1 done.

$CONTEXT_RULES

GOAL CONDITION: $run_dir/data.json exists with valid JSON and STATUS.md shows Phase 1 complete.
PROMPT
            ;;
        2)
cat <<PROMPT
/goal Run the analysis script: python3 $run_dir/analyze.py $run_dir/data.json. Save the output to $run_dir/results.txt. If the script has a bug, fix it and retry. Update STATUS.md to mark Phase 2 done.

$CONTEXT_RULES

GOAL CONDITION: $run_dir/results.txt exists with valid JSON containing total, average, and count fields, and STATUS.md shows Phase 2 complete.
PROMPT
            ;;
        3)
cat <<PROMPT
/goal Read $run_dir/results.txt. Write a one-sentence summary to $run_dir/summary.txt. Update STATUS.md to mark Phase 3 done and the pipeline as complete.

$CONTEXT_RULES

GOAL CONDITION: $run_dir/summary.txt exists and STATUS.md shows pipeline complete.
PROMPT
            ;;
        retro)
cat <<PROMPT
/goal Write a brief retrospective to $run_dir/session_retro.md. Read the phase logs at $run_dir/phase_*.log. Cover: which phases succeeded, whether /goal helped Claude self-correct, one paragraph.

$CONTEXT_RULES

GOAL CONDITION: $run_dir/session_retro.md exists with retrospective content.
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

log "Starting phases $START_PHASE → $END_PHASE (using /goal)"

for phase in $(seq "$START_PHASE" "$END_PHASE"); do
    log "--- Phase $phase (/goal) ---"

    PROMPT="$(phase_prompt "$phase" "$RUN_DIR")"
    PHASE_LOG="$RUN_DIR/phase_${phase}.log"

    log "Running phase $phase with /goal..."

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
        log "ERROR: Phase $phase failed even with /goal — stopping"
        exit 1
    fi

    # Check if goal was achieved by looking for expected outputs
    case "$phase" in
        2)
            if [ -f "$RUN_DIR/results.txt" ]; then
                log "Phase 2: results.txt exists — /goal succeeded"
            else
                log "WARNING: Phase 2 finished but results.txt missing"
            fi
            ;;
    esac

    touch "$RUN_DIR/.phase_${phase}_done"
    log "Phase $phase DONE"

    sleep 2
done

# ---- Retrospective ----
log "--- Retrospective (/goal) ---"
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

# ---- Results summary ----
log "=============================================="
log "TEST COMPLETE. Results: $RUN_DIR"
log "=============================================="

# Check if Claude fixed the bug
if [ -f "$RUN_DIR/analyze.py" ]; then
    if python3 -c "
import ast, sys
tree = ast.parse(open('$RUN_DIR/analyze.py').read())
# Check if 'counnt' appears as a Name node (actual code, not comments)
for node in ast.walk(tree):
    if isinstance(node, ast.Name) and node.id == 'counnt':
        sys.exit(1)
" 2>/dev/null; then
        log "PASS: analyze.py was fixed by Claude during /goal phase"
    else
        log "NOTE: analyze.py still has the bug (counnt) — /goal did not fix it"
    fi
fi

if [ -f "$RUN_DIR/results.txt" ]; then
    log "PASS: results.txt exists"
    log "Content: $(cat "$RUN_DIR/results.txt")"
else
    log "FAIL: results.txt missing"
fi
