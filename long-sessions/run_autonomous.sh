#!/usr/bin/env bash
# ============================================================================
# Autonomous Multi-Phase Pipeline for Claude Code
# ============================================================================
#
# Runs a multi-phase task plan using sequential Claude Code sessions.
# Each phase gets a fresh context window — no carryover, no stalling.
#
# Usage:
#   ./run_autonomous.sh                          # All phases (1-3)
#   ./run_autonomous.sh --phase 2                # Start from phase 2
#   ./run_autonomous.sh --phase 2 --until 3      # Phases 2-3 only
#   ./run_autonomous.sh --dry-run                # Print prompts, don't run
#   ./run_autonomous.sh --model sonnet           # Use a specific model
#   ./run_autonomous.sh --with-watchdog          # Auto-restart on failure
#
# How it works:
#   1. Each phase launches `claude --print` with a self-contained prompt
#   2. Claude reads STATUS.md, does the work, commits, updates STATUS.md
#   3. Script logs output and moves to the next phase
#   4. A retrospective phase runs at the end to analyze the session
#
# All logs go to runs/<timestamp>/
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"  # adjust if script lives in a subdirectory

# ---- Defaults ----
START_PHASE=1
END_PHASE=3
DRY_RUN=false
MODEL="opus"
MAX_BUDGET="10.00"
RUN_DIR_OVERRIDE=""
WITH_WATCHDOG=false

# ---- Parse arguments ----
while [[ $# -gt 0 ]]; do
    case "$1" in
        --phase)         START_PHASE="$2"; shift 2 ;;
        --until)         END_PHASE="$2"; shift 2 ;;
        --dry-run)       DRY_RUN=true; shift ;;
        --model)         MODEL="$2"; shift 2 ;;
        --budget)        MAX_BUDGET="$2"; shift 2 ;;
        --run-dir)       RUN_DIR_OVERRIDE="$2"; shift 2 ;;
        --with-watchdog) WITH_WATCHDOG=true; shift ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | grep '^#' | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# ---- Run directory ----
if [ -n "$RUN_DIR_OVERRIDE" ]; then
    RUN_DIR="$RUN_DIR_OVERRIDE"
else
    RUN_DIR="$PROJECT_ROOT/runs/$(date +%Y-%m-%d_%H%M%S)"
fi
mkdir -p "$RUN_DIR"

MASTER_LOG="$RUN_DIR/master.log"

# ---- Logging ----
log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg" | tee -a "$MASTER_LOG"
}

# ---- Watchdog (optional) ----
if $WITH_WATCHDOG && ! $DRY_RUN; then
    WATCHDOG_SCRIPT="$SCRIPT_DIR/watchdog.sh"
    if [ -f "$WATCHDOG_SCRIPT" ]; then
        nohup "$WATCHDOG_SCRIPT" "$RUN_DIR" "$$" > /dev/null 2>&1 &
        log "Watchdog started (PID $!)"
    else
        echo "WARNING: watchdog.sh not found at $WATCHDOG_SCRIPT" >&2
    fi
fi

# ---- Context management rules (injected into every prompt) ----
CONTEXT_RULES='
RULES FOR THIS SESSION:
- Redirect ALL command output to log files. Only tail summaries into conversation:
    command > some.log 2>&1
    tail -20 some.log
- Do NOT let raw API responses, HTTP logs, or verbose output enter the conversation.
- Do NOT re-read large files already in context. Use grep for lookups.
- After each milestone: git commit results and update STATUS.md.
- Keep responses SHORT. No recaps. No summaries of what you just did.
'

# ============================================================================
# PHASE PROMPTS — customize these for your project
# ============================================================================
# Each prompt should be self-contained. The only shared state between phases
# is STATUS.md and whatever files are on disk. Claude has zero memory of
# previous phases.
#
# Good prompts:
#   - Start with "Read STATUS.md for context"
#   - Specify the run directory for output files
#   - List concrete tasks, not vague goals
#   - End with "commit results, update STATUS.md"
# ============================================================================

phase_prompt() {
    local phase="$1"
    local run_dir="$2"

    case "$phase" in
        1)
cat <<PROMPT
Read STATUS.md for context. Execute Phase 1.

Run directory: $run_dir

TASKS:
1. [Your first task — e.g., set up test data, run baseline]
2. [Your second task — e.g., generate initial results]
3. Save results to $run_dir/
4. Commit results, update STATUS.md with what was accomplished

$CONTEXT_RULES
PROMPT
            ;;
        2)
cat <<PROMPT
Read STATUS.md for context. Execute Phase 2.

Run directory: $run_dir

TASKS:
1. [Build on Phase 1 results — e.g., run experiments, iterate]
2. [Your second task]
3. Save results to $run_dir/
4. Commit results, update STATUS.md

$CONTEXT_RULES
PROMPT
            ;;
        3)
cat <<PROMPT
Read STATUS.md for context. Execute Phase 3.

Run directory: $run_dir

TASKS:
1. [Final phase — e.g., validate, analyze, write summary]
2. Save results to $run_dir/
3. Commit results, update STATUS.md with final state

$CONTEXT_RULES
PROMPT
            ;;
        retro)
cat <<PROMPT
You just finished a multi-phase autonomous run. Write a retrospective.

Run directory: $run_dir
Phase logs: $run_dir/phase_1.log through phase_${END_PHASE}.log

Write $run_dir/session_retro.md covering:
1. Phase execution summary — what succeeded, what failed, duration
2. Context management — did output redirection work? Any signs of pressure?
3. What worked well in the autonomous setup
4. What should change for next time
5. Recommendations

Be honest and specific. Use actual log data, not speculation.
Do NOT commit — just write the retro file.

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

log "=============================================="
log "Autonomous Pipeline"
log "=============================================="
log "Run directory: $RUN_DIR"
log "Phases: $START_PHASE → $END_PHASE + retro"
log "Model: $MODEL | Budget: \$$MAX_BUDGET per phase"
log ""

for phase in $(seq "$START_PHASE" "$END_PHASE"); do
    log "--- Phase $phase of $END_PHASE ---"

    PROMPT="$(phase_prompt "$phase" "$RUN_DIR")"
    PHASE_LOG="$RUN_DIR/phase_${phase}.log"

    if $DRY_RUN; then
        log "[DRY RUN] Phase $phase prompt:"
        echo "$PROMPT" | tee -a "$MASTER_LOG"
        echo ""
        continue
    fi

    log "Starting phase $phase (log: $PHASE_LOG)"

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

    log "Phase $phase finished (exit code: $EXIT_CODE)"
    log "Log size: $(du -h "$PHASE_LOG" | cut -f1)"

    # Show tail of output
    log "--- Last 10 lines ---"
    tail -10 "$PHASE_LOG" | tee -a "$MASTER_LOG"
    log "--- End phase $phase ---"
    echo ""

    if [ $EXIT_CODE -ne 0 ]; then
        log "WARNING: Phase $phase exited with code $EXIT_CODE"
        log "Check $PHASE_LOG for details"
    fi

    sleep 5
done

# ---- Retrospective ----
if ! $DRY_RUN; then
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
        log "Retrospective: $RUN_DIR/session_retro.md"
    else
        log "WARNING: Retrospective file not found — check $RETRO_LOG"
    fi
fi

log "=============================================="
log "All phases complete. Results: $RUN_DIR"
log "=============================================="
