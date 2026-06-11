---
description: "Display RAG session status and project stats. Sessions start automatically via the SessionStart hook — use this command to check state, or to start a session manually if the hook didn't."
disable-model-invocation: true
---

# RAG Session Status

Display the current RAG session status and project overview. Session startup is
handled automatically by the plugin's SessionStart hook — this command is
primarily a status display.

## Steps

1. Check for an active session (the SessionStart hook starts one and injects
   `RAG_SESSION_ID`). Display status:

   ```
   ## Session Status
   - Session ID: {sessionId, or "none — hook did not start a session"}
   - Project: {projectName}
   - Sensory buffer: active (captures tool calls)
   - Working memory: active (promotes high-salience events)
   ```

2. Run `get_project_stats` to show project overview:

   ```
   ### Project Stats
   - Codebase vectors: {count}
   - Memory (durable): {count}
   - Memory (semantic LTM): {count}
   - Graph edges: {count}
   ```

3. **Fallback only** — if no session is active (hook failed or was skipped),
   start one manually:

   ```
   start_session(initialContext: "$ARGUMENTS")
   ```

   If `$ARGUMENTS` is empty, use: `start_session(initialContext: "manual session start")`

4. If a session was already active, say so and show the existing session ID —
   do not start a second one.
