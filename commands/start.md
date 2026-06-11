---
description: "Start a RAG session and display current status. User-invoked at the beginning of work or to check session state."
disable-model-invocation: true
---

# RAG Session Start

Initialize a RAG session for the current project and display status.

## Steps

1. Start a new session:

   ```
   start_session(initialContext: "$ARGUMENTS")
   ```

   If `$ARGUMENTS` is empty, use: `start_session(initialContext: "manual session start")`

2. Display status:

   ```
   ## Session Started
   - Session ID: {sessionId}
   - Project: {projectName}
   - Sensory buffer: active (captures tool calls)
   - Working memory: active (promotes high-salience events)
   ```

3. Run `get_project_stats` to show project overview:

   ```
   ### Project Stats
   - Codebase vectors: {count}
   - Memory (durable): {count}
   - Memory (semantic LTM): {count}
   - Graph edges: {count}
   ```

4. If the session was already active, say so and show the existing session ID.
