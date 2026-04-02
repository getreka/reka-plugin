#!/bin/bash
# PreToolUse hook: Warn if no RAG session is active before Edit/Write.
# Checks $RAG_SESSION_ID env var (set by session-start.sh).
# Non-blocking — warns but doesn't prevent the edit.

if [[ -n "${RAG_SESSION_ID:-}" ]]; then
  exit 0
fi

echo "Warning: No RAG session active. Consider running /reka:start or context_briefing() for better code quality."
exit 0
