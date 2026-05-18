# Long Autonomous Session: What Happened and How to Improve

## The Task

You gave me 12 hours to work, including interactive planning and then autonomous overnight work:
- Expand the question set to 100+ questions
- Run the full V0->V1->V2 skill evolution pipeline
- Experiment with prompts, conversations, and LLM behavior
- Create a demo runner script and draft a blog post
- Commit work frequently

## What Happened

I worked from **3:18 PM to ~12:50 AM PST** (~9.5 hours) before the
**context window filled up** and the session terminated. The context
window is the total amount of text (my reasoning + tool inputs/outputs)
that fits in a single conversation. Once it's full, the session ends --
I can't continue working, even if there's more to do.

### Why the context filled up so fast

Each experiment consumed large amounts of context:

1. **Verbose LLM API logs**: Every HTTP request to Gemini printed
   multi-line log output (headers, URLs, status codes). Running 109
   conversations generated thousands of log lines.
2. **Full conversation dumps**: The traffic generator prints every
   turn of every conversation to stdout. 109 multi-turn conversations
   = massive output per run.
3. **Multiple full pipeline runs**: V0 baseline + V1 test + V2 test +
   V2+fix test = 4 full runs of 109 conversations each.
4. **Reading large files**: Quality reports, blog drafts, and code
   files all consumed context when read.
5. **No automatic continuation**: When context runs out, Claude Code
   stops. There's no built-in mechanism to automatically start a new
   session and continue.

## Recommendations for Next Time

### 1. Break work into sequential sessions

Instead of one 8-hour task, give 2-3 focused tasks with checkpoints:
- Session 1: "Build pipeline and run V0 baseline. Commit and stop."
- Session 2: "Continue from branch X. Run V1/V2 evolution. Commit."
- Session 3: "Run experiments and write blog. Commit."

Each session starts fresh with full context budget.

### 2. Suppress verbose output in scripts

Add to CLAUDE.md or task instructions:
> "When running long experiments, always redirect verbose output to
> files and only tail the last 10-20 lines. Use `2>&1 | tail -20`
> or redirect to log files."

This prevents thousands of HTTP log lines from filling context.

### 3. Add a context-efficiency reminder to CLAUDE.md

```
For long autonomous sessions:
- Suppress verbose logs (pipe to files, tail summaries)
- Avoid re-reading files already in context
- Use grep over full file reads when possible
- Commit and write STATUS.md at each milestone
- If context is getting large, proactively start a new session
```

### 4. Use checkpoint files for handoff

Ask me to write a `STATUS.md` at each milestone with:
- What's done
- What's next
- Key file paths
- Any decisions or findings

This makes session handoff seamless -- the new session reads STATUS.md
and continues without needing to re-discover everything.

### 5. Run background commands for heavy workloads

Long-running commands (traffic generation, quality scoring) can be run
in background mode, which uses less context than inline execution. But
even background commands' results consume context when they report back.

### 6. Redirect experiment output to files

Instead of printing results to stdout (which enters context), write
them to JSON/log files and only read summaries:

```bash
# Instead of this (floods context):
python run_experiment.py

# Do this (saves context):
python run_experiment.py > eval/experiment.log 2>&1
tail -5 eval/experiment.log  # Only summary enters context
```

## What You Could Have Done Differently

Honestly, not much -- this was a learning experience for both of us.
The main actionable change: **add the log-suppression and checkpoint
instructions to the task prompt or CLAUDE.md** so the session stays
lean. The 8-hour budget was realistic for the amount of work; the
bottleneck was context efficiency, not time.
