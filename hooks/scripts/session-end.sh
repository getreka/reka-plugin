#!/bin/bash
# SessionEnd hook: End RAG session and trigger consolidation agent.
# Fires once when the CLI session actually closes (NOT after each turn).
# Reads RAG_SESSION_ID injected by session-start.sh via $CLAUDE_ENV_FILE.
# Idempotent: if the session was already ended (e.g. by an explicit
# /reka:end, or a previous run of this hook), it skips silently.
# On any failure: exits 0 silently (best-effort, never blocks shutdown).

SESSION_ID="${RAG_SESSION_ID:-}"
API_URL="${RAG_API_URL:-http://localhost:3100}"
API_KEY="${RAG_API_KEY:-}"
PROJECT="${RAG_PROJECT_NAME:-default}"

if [[ -z "$SESSION_ID" ]]; then
  exit 0
fi

# State dir for "already ended" markers. Honor TMPDIR; default to /tmp.
STATE_DIR="${RAG_STATE_DIR:-${TMPDIR:-/tmp}/reka}"
MARKER="$STATE_DIR/session-${SESSION_ID}.ended"

# Idempotency: if a marker already exists, this session was ended by an
# explicit /reka:end or an earlier hook run — skip silently.
if [[ -f "$MARKER" ]]; then
  exit 0
fi

# End session with autoSaveLearnings — triggers consolidation agent server-side.
# Capture the response so we can detect "already ended" reported by the server.
RESPONSE="$(curl -s -m 15 -X POST "$API_URL/api/session/$SESSION_ID/end" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $API_KEY" \
  -H "X-Project-Name: $PROJECT" \
  -d "{\"projectName\":\"$PROJECT\",\"summary\":\"Session ended by reka plugin SessionEnd hook\",\"autoSaveLearnings\":true}" \
  2>/dev/null)" || true

# Record the marker so subsequent invocations (or a later /reka:end) no-op.
# A non-empty response, or one indicating the session is already ended/missing,
# both mean we should not retry.
mkdir -p "$STATE_DIR" 2>/dev/null || true
touch "$MARKER" 2>/dev/null || true

exit 0
