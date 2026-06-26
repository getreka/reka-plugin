#!/bin/bash
# SessionEnd hook: ship the session transcript to the user's rag-api, then end
# the RAG session and trigger the consolidation agent.
# Fires when the CLI session closes (NOT after each turn) — but SessionEnd is
# not guaranteed on every termination path (terminal close, SIGKILL), so the
# server ALSO ends idle sessions on its maintenance cycle (rag-api
# sweepIdleSessions). This hook is the fast path; the server sweep is the net.
# Reads RAG_SESSION_ID / RAG_PROJECT_NAME injected by session-start.sh via
# $CLAUDE_ENV_FILE; re-resolves the key/url durably if a restart dropped them.
# Idempotent: an already-ended session (explicit /reka:end or a prior run) skips.
# On any failure: exits 0 silently (best-effort, never blocks shutdown).

# Durable env resolution (covers the case where CLAUDE_ENV_FILE injection from
# session-start didn't reach this process — e.g. a restart dropped the key).
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/rag-env.sh
. "$HOOK_DIR/lib/rag-env.sh" 2>/dev/null && reka_resolve || true

SESSION_ID="${RAG_SESSION_ID:-}"
API_URL="${RAG_API_URL:-http://localhost:3100}"
API_KEY="${RAG_API_KEY:-}"
# Tenant header: the session's project (from session-start) or the key-derived
# namespace, else 'default' for the anonymous path. No projectName in body/query
# (the server's enforceProjectScope would 403 a mismatch; the header carries it).
PROJECT="${RAG_PROJECT_NAME:-${REKA_PROJECT:-default}}"

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
# Ships the transcript tail to the user's own rag-api — the ONLY destination is
# $RAG_API_URL; no other egress. Opt out with REKA_TRANSCRIPT_CAPTURE=0. Runs
# before the marker guard and does not need RAG_SESSION_ID (capture keys on the
# CC session id); repeat POSTs per sessionId are cheap server-side no-ops.
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

# State dir for "already ended" markers. Default to the XDG state dir so the
# marker survives WSL /tmp wipes; honor RAG_STATE_DIR / TMPDIR overrides.
STATE_DIR="${RAG_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/reka}"
MARKER="$STATE_DIR/session-${SESSION_ID}.ended"

# Idempotency: if a marker already exists, this session was ended by an explicit
# /reka:end or an earlier hook run — skip silently. (There is a small TOCTOU
# window between this check and the touch below; the /api/session/:id/end route
# is idempotent server-side, which is the backstop for a concurrent double-fire.)
if [[ -f "$MARKER" ]]; then
  exit 0
fi

# End session with autoSaveLearnings — triggers consolidation agent server-side.
# No projectName in the body (enforceProjectScope); the tenant rides the header.
# -m12 keeps capture(-m10) + end(-m12) under the SessionEnd hook timeout (25s).
curl -s -m 12 -X POST "$API_URL/api/session/$SESSION_ID/end" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $API_KEY" \
  -H "X-Project-Name: $PROJECT" \
  -d '{"summary":"Session ended by reka plugin SessionEnd hook","autoSaveLearnings":true}' \
  >/dev/null 2>&1 || true

# Record the marker so subsequent invocations (or a later /reka:end) no-op.
mkdir -p "$STATE_DIR" 2>/dev/null || true
touch "$MARKER" 2>/dev/null || true

exit 0
