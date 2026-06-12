#!/bin/bash
# SessionEnd hook: ship the session transcript to the user's rag-api, then
# end the RAG session and trigger consolidation agent.
# Fires once when the CLI session actually closes (NOT after each turn).
# Reads RAG_SESSION_ID injected by session-start.sh via $CLAUDE_ENV_FILE.
# Idempotent: if the session was already ended (e.g. by an explicit
# /reka:end, or a previous run of this hook), the end call skips silently;
# transcript capture is idempotent server-side (keyed on the CC session id).
# On any failure: exits 0 silently (best-effort, never blocks shutdown).

SESSION_ID="${RAG_SESSION_ID:-}"
API_URL="${RAG_API_URL:-http://localhost:3100}"
API_KEY="${RAG_API_KEY:-}"
PROJECT="${RAG_PROJECT_NAME:-default}"

# Hook stdin: compact JSON from Claude Code with at least session_id and
# transcript_path. May be empty; parsed with grep/sed (no jq dependency).
HOOK_INPUT="$(cat 2>/dev/null || true)"
CC_SESSION_ID="$(printf '%s' "$HOOK_INPUT" \
  | grep -o '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 \
  | sed 's/.*"\([^"]*\)"$/\1/')"
TRANSCRIPT_PATH="$(printf '%s' "$HOOK_INPUT" \
  | grep -o '"transcript_path"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 \
  | sed 's/.*"\([^"]*\)"$/\1/')"

# ── Transcript capture ───────────────────────────────────────────────────────
# Ships the transcript tail to the user's own rag-api — the ONLY destination
# is $RAG_API_URL; no other egress. Opt out with REKA_TRANSCRIPT_CAPTURE=0.
# Runs before the marker guard (an /reka:end marker must not suppress it) and
# does not need RAG_SESSION_ID (capture keys on the CC session id); repeat
# POSTs per sessionId are cheap server-side no-ops, so no client marker.
# API_KEY may be empty — still attempt (server may run ALLOW_ANONYMOUS).
# Last 2 MiB only; the server tolerates a truncated first line.
if [[ "${REKA_TRANSCRIPT_CAPTURE:-1}" != "0" \
  && -n "$CC_SESSION_ID" && -n "$TRANSCRIPT_PATH" \
  && -f "$TRANSCRIPT_PATH" && -r "$TRANSCRIPT_PATH" ]]; then
  tail -c 2097152 "$TRANSCRIPT_PATH" \
    | curl -s -m 10 -X POST "$API_URL/api/capture/transcript?sessionId=$CC_SESSION_ID" \
      -H "Content-Type: text/plain" \
      -H "Authorization: Bearer $API_KEY" \
      -H "X-Project-Name: $PROJECT" \
      --data-binary @- >/dev/null 2>&1 || true
fi

# ── End RAG session ──────────────────────────────────────────────────────────
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
