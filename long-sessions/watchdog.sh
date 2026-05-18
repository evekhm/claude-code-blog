#!/usr/bin/env bash
# ============================================================================
# Watchdog for Autonomous Claude Code Pipeline
# ============================================================================
#
# Monitors the orchestrator process and restarts it if it dies.
# Checks every 2 minutes. If the same phase fails twice, launches a
# Claude diagnostic session to read the log and attempt a fix.
#
# Usage:
#   ./watchdog.sh <run-dir> <orchestrator-pid>
#
# Launched automatically by run_autonomous.sh --with-watchdog.
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Arguments
RUN_DIR="${1:?Usage: watchdog.sh <run-dir> <orchestrator-pid>}"
ORCH_PID="${2:?Usage: watchdog.sh <run-dir> <orchestrator-pid>}"
WATCHDOG_LOG="$RUN_DIR/watchdog.log"

MAX_RESTARTS=3
RESTART_COUNT=0
LAST_FAILED_PHASE=""
SAME_PHASE_FAILURES=0

ORCHESTRATOR_SCRIPT="$SCRIPT_DIR/run_autonomous.sh"

wlog() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$WATCHDOG_LOG"
}

is_orchestrator_running() {
    kill -0 "$ORCH_PID" 2>/dev/null
}

detect_last_completed_phase() {
    local last=0
    for i in 1 2 3 4 5; do
        local log="$RUN_DIR/phase_${i}.log"
        if [ -f "$log" ] && [ -s "$log" ]; then
            last=$i
        else
            break
        fi
    done
    echo "$last"
}

# Use Claude to diagnose a failed phase and attempt a fix
diagnose_and_fix() {
    local failed_phase="$1"
    local phase_log="$RUN_DIR/phase_${failed_phase}.log"
    local diag_log="$RUN_DIR/diagnostic_phase${failed_phase}.log"

    wlog "Launching Claude diagnostic session for phase $failed_phase"

    local diag_prompt
    diag_prompt=$(cat <<DIAG
Phase $failed_phase of the experiment orchestrator just crashed.

The phase log is at: $phase_log
The run directory is: $RUN_DIR
The master log is at: $RUN_DIR/master.log

Your job:
1. Read the last 100 lines of the phase log to understand what went wrong.
2. Diagnose the root cause.
3. If it's a fixable issue (script bug, missing file, wrong state), fix it.
   - If you fix something, commit with a clear message.
4. If it's unfixable (API quota, infra issue, fundamental design problem),
   write your diagnosis to $RUN_DIR/diagnostic_phase${failed_phase}.md
   so the next restart or the user can see what happened.
5. Keep it SHORT. Diagnose, fix if possible, done.

Do NOT re-run the experiment phase itself. Just fix the environment so
the next restart succeeds.
DIAG
)

    set +e
    claude \
        --print \
        --dangerously-skip-permissions \
        --model sonnet \
        --max-budget-usd 5.00 \
        "$diag_prompt" \
        < /dev/null \
        > "$diag_log" 2>&1
    local diag_exit=$?
    set -e

    wlog "Diagnostic session finished (exit code: $diag_exit, log: $diag_log)"

    if [ -f "$RUN_DIR/diagnostic_phase${failed_phase}.md" ]; then
        wlog "Diagnostic written: $(head -3 "$RUN_DIR/diagnostic_phase${failed_phase}.md")"
    fi
}

wlog "Watchdog started for run: $RUN_DIR"
wlog "Monitoring orchestrator PID: $ORCH_PID"

while true; do
    sleep 120  # Check every 2 minutes

    if is_orchestrator_running; then
        LAST_PHASE=$(detect_last_completed_phase)
        DIR_SIZE=$(du -sh "$RUN_DIR" 2>/dev/null | cut -f1)
        wlog "OK — orchestrator running, $LAST_PHASE phases complete, dir size: $DIR_SIZE"
        RESTART_COUNT=0
        continue
    fi

    # Orchestrator is NOT running
    LAST_PHASE=$(detect_last_completed_phase)
    NEXT_PHASE=$((LAST_PHASE + 1))

    # Check if retro is done
    if [ -f "$RUN_DIR/session_retro.md" ]; then
        wlog "DONE — all phases complete including retro. Watchdog exiting."
        break
    fi

    if [ "$LAST_PHASE" -ge 5 ]; then
        wlog "All experiment phases complete. Watchdog exiting."
        break
    fi

    # Track same-phase failures
    if [ "$NEXT_PHASE" = "$LAST_FAILED_PHASE" ]; then
        SAME_PHASE_FAILURES=$((SAME_PHASE_FAILURES + 1))
    else
        SAME_PHASE_FAILURES=1
        LAST_FAILED_PHASE="$NEXT_PHASE"
    fi

    RESTART_COUNT=$((RESTART_COUNT + 1))
    if [ "$RESTART_COUNT" -gt "$MAX_RESTARTS" ]; then
        wlog "ERROR — exceeded $MAX_RESTARTS total restarts. Giving up."
        break
    fi

    wlog "ALERT — orchestrator died after phase $LAST_PHASE (attempt $SAME_PHASE_FAILURES for phase $NEXT_PHASE)"

    # If same phase failed twice, run diagnosis before retrying
    if [ "$SAME_PHASE_FAILURES" -ge 2 ]; then
        wlog "Phase $NEXT_PHASE failed $SAME_PHASE_FAILURES times — running Claude diagnostic"
        diagnose_and_fix "$LAST_PHASE"
    fi

    # Restart from next phase
    nohup "$ORCHESTRATOR_SCRIPT" \
        --phase "$NEXT_PHASE" \
        --run-dir "$RUN_DIR" \
        < /dev/null \
        >> "$RUN_DIR/master.log" 2>&1 &
    ORCH_PID=$!

    wlog "Restarted orchestrator (PID $ORCH_PID), resuming from phase $NEXT_PHASE"

    sleep 30
done

wlog "Watchdog stopped."
