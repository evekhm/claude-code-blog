## Context Management (CRITICAL for long sessions)

When running any command that produces
verbose output:

1. **Always redirect output to files**, then tail the summary:
   ```bash
   command_here > some_log.log 2>&1
   tail -20 some_log.log
   ```
2. **Never let raw HTTP/API logs enter the conversation.** Use `2>&1 | tail -N`.
3. **Don't re-read files already in context.** Use grep for specific lookups.
4. **After every major milestone**, update `STATUS.md` at the repo root with:
   - What was just completed
   - What's next
   - Key results (numbers, not raw data)

## Session Handoff

- `STATUS.md` at repo root is the handoff document. Read it at session start.
- Always update STATUS.md before ending a session.
