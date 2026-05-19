# Autonomous Claude Code Pipeline — Companion Scripts

Scripts and examples from the blog post: [Running Claude Code Autonomously Overnight](BLOG.md).

## Prerequisites

- **Claude Code CLI** installed and authenticated (`claude --version`)
- **Bash 4+** (`bash --version`)
- **Python 3.6+** (for the test scenario)
- A terminal that supports `nohup` (any Linux/macOS terminal)

Install Claude Code if needed:

```bash
npm install -g @anthropic-ai/claude-code
```

## Files

| File | Purpose |
|------|---------|
| [BLOG.md](BLOG.md) | The blog post |
| [run_autonomous.sh](run_autonomous.sh) | Phased orchestrator — launches sequential `claude --print` sessions |
| [watchdog.sh](watchdog.sh) | Monitors the orchestrator, restarts on failure, runs Claude diagnostics |
| [example-CLAUDE.md](example-CLAUDE.md) | Context management rules to add to your project's CLAUDE.md |
| [example-STATUS.md](example-STATUS.md) | Sample STATUS.md handoff document |
| [test_e2e.sh](test_e2e.sh) | End-to-end test: watchdog detects crash, Claude diagnoses and fixes |
| [test_goal.sh](test_goal.sh) | End-to-end test: `/goal` mode, Claude self-heals within the phase |

## Quick Start

Run the included end-to-end test to see the full pipeline in action — orchestrator, watchdog, and Claude-as-diagnostician. No configuration needed.

The test creates a **deliberate bug** (a Python `NameError` in `analyze.py`) and lets the pipeline crash, recover, diagnose, fix, and complete — all autonomously.

### 1. Run the test

```bash
cd long-sessions
nohup ./test_e2e.sh > /dev/null 2>&1 &
```

### 2. Watch it work

```bash
# Watch the watchdog (updates every 30 seconds):
tail -f runs/test_*/watchdog.log

# Or the master log for phase-level detail:
tail -f runs/test_*/master.log
```

### What happens

1. **Phase 1** — Claude creates a `data.json` file (succeeds)
2. **Phase 2** — Orchestrator runs a buggy `analyze.py` (fails with `NameError`)
3. **Watchdog** detects the crash, restarts, fails again on the same bug
4. **Claude diagnostic** — watchdog launches a Claude session that reads the error log, finds the bug, and fixes it
5. **Phase 2 retry** — the fixed script runs successfully
6. **Phase 3** — Claude writes a summary (succeeds)
7. **Retrospective** — Claude writes a session retro

### Run it

```bash
# Launch in background:
nohup ./test_e2e.sh > /dev/null 2>&1 &

# Monitor progress (watchdog checks every 30 seconds):
tail -f runs/test_*/watchdog.log

# Or watch the master log:
tail -f runs/test_*/master.log
```

### Expected output

The test takes **~3 minutes** and costs **~$1-2** (uses Sonnet).

In `watchdog.log` you should see:

```
[...] Watchdog started for run: runs/test_...
[...] Check interval: 30s
[...] ALERT — orchestrator died after phase 1 (attempt 1 for phase 2)
[...] Restarted orchestrator (PID ...), resuming from phase 2
[...] ALERT — orchestrator died after phase 1 (attempt 2 for phase 2)
[...] Phase 2 failed 2 times — running Claude diagnostic
[...] Launching Claude diagnostic session for phase 2
[...] Diagnostic session finished (exit code: 0, ...)
[...] Restarted orchestrator (PID ...), resuming from phase 2
[...] DONE — all phases complete including retro. Watchdog exiting.
[...] Watchdog stopped.
```

Timeline from a real run:

| Time | Event |
|------|-------|
| 0:00 | Phase 1 starts, creates data.json |
| 0:14 | Phase 1 done, Phase 2 hits `NameError: counnt`, orchestrator exits |
| 0:30 | Watchdog detects crash, restarts (attempt 1) |
| 0:30 | Phase 2 fails again (same bug), orchestrator exits |
| 1:30 | Watchdog detects second failure, launches Claude diagnostic |
| 1:52 | Claude reads error log, fixes `counnt` → `len(data)`, commits |
| 1:52 | Watchdog restarts orchestrator (attempt 2) |
| 2:xx | Phase 2 succeeds, Phase 3 completes, retro written |
| 2:52 | Watchdog sees retro, exits cleanly |

### Verify results

```bash
RUN_DIR=$(ls -td runs/test_*/ | head -1)

# Check the fixed script (counnt → len(data)):
cat "$RUN_DIR/analyze.py"

# Check results:
cat "$RUN_DIR/results.txt"
cat "$RUN_DIR/summary.txt"
cat "$RUN_DIR/session_retro.md"

# Check diagnostic log (how Claude found and fixed the bug):
cat "$RUN_DIR/diagnostic_phase2.log"
```

Expected `results.txt`:

```json
{
  "total": 60,
  "average": 20.0,
  "count": 3
}
```

Expected `diagnostic_phase2.log` (Claude's diagnosis):

```
Fixed. Phase 2 crashed due to typo in analyze.py:12 - `counnt` (undefined)
instead of `len(data)`. Fixed and committed. Next restart should succeed.
```

### Cleanup

```bash
rm -rf runs/test_*
rm -f STATUS.md
```

## Alternative: `/goal` Mode (Self-Healing Phases)

Instead of relying on the watchdog to detect and fix failures, you can use Claude Code's [`/goal`](https://code.claude.com/docs/en/goal) command to make each phase self-healing.

### How `/goal` changes the behavior

Without `/goal`, `claude --print` runs **one turn**. If a script fails, Claude reports the error and exits. The process returns exit code 0 (Claude ran fine, even though the task failed). The orchestrator has no way to know the task didn't succeed.

With `/goal`, after each turn a small fast model (Haiku) evaluates whether the **goal condition** is met — for example, *"does results.txt exist with valid JSON?"*. If not, `/goal` automatically starts another turn. Claude sees the error from the previous turn, fixes the bug, and retries. The evaluator checks again. This repeats until the condition is met or the budget runs out.

The key difference: `/goal` adds an **external judge** that checks whether the task succeeded, not just whether Claude's process ran. This is what makes phases self-healing.

### Run the `/goal` test

Same buggy `analyze.py` script (NameError: `counnt`), but Claude fixes it within Phase 2 instead of crashing and waiting for the watchdog:

```bash
nohup ./test_goal.sh > /dev/null 2>&1 &
tail -f runs/goal_*/master.log
```

**Duration**: ~2 minutes. **Cost**: ~$0.50-1 (fewer sessions than the watchdog test).

### Expected output

```
[...] GOAL TEST: /goal self-healing phases
[...] Created buggy analyze.py (has NameError: 'counnt')
[...] Starting phases 1 → 3 (using /goal)
[...] --- Phase 1 (/goal) ---
[...] Running phase 1 with /goal...
[...] Phase 1 DONE
[...] --- Phase 2 (/goal) ---
[...] Running phase 2 with /goal...
[...] Fixed typo in analyze.py (counnt → len(data)), ran script,
      saved valid JSON to results.txt, and marked Phase 2 complete
[...] Phase 2: results.txt exists — /goal succeeded
[...] Phase 2 DONE
[...] --- Phase 3 (/goal) ---
[...] Phase 3 DONE
[...] --- Retrospective (/goal) ---
[...] Retrospective written: .../session_retro.md
[...] PASS: analyze.py was fixed by Claude during /goal phase
[...] PASS: results.txt exists
[...] Content: {"total": 60, "average": 20.0, "count": 3}
```

Notice Phase 2 — Claude ran the buggy script, hit the NameError, fixed `counnt` → `len(data)`, retried, and succeeded. All within one phase, in ~37 seconds. No watchdog, no restart, no separate diagnostic session.

### Watchdog vs `/goal` — comparison

| | Watchdog (`test_e2e.sh`) | `/goal` (`test_goal.sh`) |
|---|---|---|
| **How it recovers** | External: watchdog polls, detects crash, launches Claude diagnostic, restarts | Internal: evaluator detects failure, Claude retries within the phase |
| **Number of Claude sessions** | 5+ (phases + diagnostic + retries) | 4 (one per phase, retries happen inside) |
| **Duration** | ~3 min (watchdog polling adds latency) | ~2 min (no polling delay) |
| **Handles process crashes** | Yes | No |
| **Handles context overflow** | Yes (each restart is fresh) | No (retries share the same context) |
| **Best for** | Long overnight runs, infrastructure failures | Shorter tasks, script-level bugs |

For maximum resilience, combine both: `/goal` handles bugs within each phase, the watchdog handles process-level crashes.

### Using `/goal` with the orchestrator

```bash
# Self-healing phases (Claude retries on failure):
./run_autonomous.sh --use-goal

# Belt and suspenders (goal + watchdog):
nohup ./run_autonomous.sh --use-goal --with-watchdog > /dev/null 2>&1 &
```

## Customize for Your Project (Optional)

Once you've seen the test work, adapt the orchestrator for your own tasks.

### 1. Edit phase prompts

Open `run_autonomous.sh` and replace the placeholder prompts in `phase_prompt()` (around line 111):

```bash
# Each prompt should:
#   - Start with "Read STATUS.md for context"
#   - Specify concrete tasks (not vague goals)
#   - End with "commit results, update STATUS.md"
```

### 2. Create a STATUS.md

Create `STATUS.md` in your project root with the initial state. See [example-STATUS.md](example-STATUS.md) for the format.

### 3. Add context rules to your CLAUDE.md

Copy the rules from [example-CLAUDE.md](example-CLAUDE.md) into your project's `CLAUDE.md`. The output redirection rule is the most important — it prevents verbose tool output from flooding the context window.

### 4. Run it

```bash
# Foreground (see output live):
./run_autonomous.sh

# With /goal (self-healing phases):
./run_autonomous.sh --use-goal

# Background with watchdog (overnight runs):
nohup ./run_autonomous.sh --with-watchdog > /dev/null 2>&1 &

# Maximum resilience (both):
nohup ./run_autonomous.sh --use-goal --with-watchdog > /dev/null 2>&1 &

# Monitor:
tail -f runs/<timestamp>/master.log
tail -f runs/<timestamp>/watchdog.log
```

### Options

```
./run_autonomous.sh [options]

  --phase N           Start from phase N (default: 1)
  --until N           End at phase N (default: 3)
  --model MODEL       Claude model to use (default: opus)
  --budget AMOUNT     Max cost per phase in USD (default: 10.00)
  --run-dir DIR       Reuse an existing run directory
  --with-watchdog     Auto-start the watchdog for crash recovery
  --use-goal          Use /goal for self-healing phases (Claude retries on failure)
  --dry-run           Print prompts without running Claude
  -h, --help          Show help
```

## How It Works

```
┌─────────────┐      ┌──────────────────────────────────┐
│ You (nohup) │─────▶│  run_autonomous.sh (orchestrator)│
└─────────────┘      │                                  │
                     │  Phase 1 ──▶ claude --print      │
                     │  Phase 2 ──▶ claude --print      │
                     │  Phase 3 ──▶ claude --print      │
                     │  Retro   ──▶ claude --print      │
                     └──────────────────────────────────┘
                           │              ▲
                    STATUS.md          restart
                    (handoff)        (if crashed)
                           │              │
                    ┌───────────────────────────────────┐
                    │  watchdog.sh                      │
                    │                                   │
                    │  - Polls every N seconds          │
                    │  - Detects which phase completed  │
                    │  - On repeated failure:           │
                    │    claude --print (diagnostic)    │
                    │    → reads error log              │
                    │    → fixes the bug                │
                    │  - Restarts orchestrator          │
                    └───────────────────────────────────┘
```

Each `claude --print` session is independent — fresh context window, no memory of previous phases. Phases communicate through files on disk (`STATUS.md`, run directory artifacts), not conversation context.
