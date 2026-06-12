#!/bin/bash
# SessionStart hook: Auto-start RAG session, inject env vars, and emit the
# session digest to stdout (Claude Code injects SessionStart-hook stdout into
# context — guaranteed delivery beats retrieval).
# Reads config from CLAUDE_PLUGIN_OPTION_* env vars (set by userConfig).
# On any failure: exits 0 silently (fallback: ensureSession() in MCP middleware).
# Dependencies: curl (standard). jq optional (has shell fallback).

set -euo pipefail

# Unset -> localhost default; explicitly empty -> hook disabled (exit 0 below).
RAG_API_URL="${CLAUDE_PLUGIN_OPTION_RAG_API_URL-http://localhost:3100}"
RAG_API_KEY="${CLAUDE_PLUGIN_OPTION_RAG_API_KEY:-}"
PROJECT_NAME="${CLAUDE_PLUGIN_OPTION_PROJECT_NAME:-default}"

if [ -z "$RAG_API_URL" ]; then
  exit 0
fi

# Start session
RESPONSE=$(curl -s -m 5 -X POST "$RAG_API_URL/api/session/start" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $RAG_API_KEY" \
  -H "X-Project-Name: $PROJECT_NAME" \
  -d "{\"projectName\":\"$PROJECT_NAME\",\"initialContext\":\"auto-started by reka plugin SessionStart hook\"}" \
  2>/dev/null || echo "")

if [ -z "$RESPONSE" ]; then
  exit 0
fi

# Parse session ID: try jq, fallback to sed (portable across macOS/Linux)
if command -v jq &>/dev/null; then
  SESSION_ID=$(echo "$RESPONSE" | jq -r '.session.sessionId // .sessionId // empty' 2>/dev/null || echo "")
else
  SESSION_ID=$(echo "$RESPONSE" | sed -n 's/.*"sessionId"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
fi

# Inject env vars into Claude Code session
if [ -n "$SESSION_ID" ] && [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  echo "export RAG_SESSION_ID=$SESSION_ID" >> "$CLAUDE_ENV_FILE"
  echo "export RAG_PROJECT_NAME=$PROJECT_NAME" >> "$CLAUDE_ENV_FILE"
  echo "export RAG_API_URL=$RAG_API_URL" >> "$CLAUDE_ENV_FILE"
  echo "export RAG_API_KEY=$RAG_API_KEY" >> "$CLAUDE_ENV_FILE"
fi

# Fetch the session digest and emit it to stdout for context injection.
# The response body IS the markdown digest (Content-Type text/markdown, no
# JSON wrapper — no jq needed). sessionId as query param so delivery is
# logged server-side (retrieval audit log, surface='digest').
# Fail-silent: -f drops HTTP-error bodies, any failure -> no output, exit 0.
if [ -n "$SESSION_ID" ]; then
  DIGEST=$(curl -fs -m 5 \
    "$RAG_API_URL/api/session/digest?projectName=$PROJECT_NAME&sessionId=$SESSION_ID" \
    -H "Authorization: Bearer $RAG_API_KEY" \
    -H "X-Project-Name: $PROJECT_NAME" \
    2>/dev/null || echo "")
  if [ -n "$DIGEST" ]; then
    echo "$DIGEST"
  fi
fi

exit 0
