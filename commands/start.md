---
description: "Start a RAG session and display current status. Use at the beginning of work or when you need to check session state. Triggers on: 'start session', 'розпочни', 'rag start', 'session status'."
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
   - Memory (episodic): {count}
   - Memory (semantic): {count}
   - Graph edges: {count}
   ```

4. If the session was already active, say so and show the existing session ID.
