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
type reka_log >/dev/null 2>&1 || reka_log() { :; }

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
if type reka_cc_session_id >/dev/null 2>&1; then
  CC_SESSION_ID="$(reka_cc_session_id "$HOOK_INPUT")"
else
  CC_SESSION_ID="$(printf '%s' "$HOOK_INPUT" \
    | grep -o '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 \
    | sed 's/.*"\([^"]*\)"$/\1/' | tr -cd 'A-Za-z0-9._-')"
fi
TRANSCRIPT_PATH="$(printf '%s' "$HOOK_INPUT" \
  | grep -o '"transcript_path"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 \
  | sed 's/.*"\([^"]*\)"$/\1/')"

# RAG session from the map session-start wrote (env injection never reaches
# hooks); env RAG_SESSION_ID still wins if something exported it.
if [ -z "$SESSION_ID" ] && [ -n "$CC_SESSION_ID" ] && type reka_map_read >/dev/null 2>&1; then
  reka_map_read "$CC_SESSION_ID"
  if [ -n "${REKA_MAP_SESSION:-}" ]; then
    SESSION_ID="$REKA_MAP_SESSION"
    [ -n "${REKA_MAP_PROJECT:-}" ] && PROJECT="$REKA_MAP_PROJECT"
    [ -n "${REKA_MAP_URL:-}" ] && API_URL="$REKA_MAP_URL"
  fi
fi

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

# ── Memory-file sync (ADR-006 Phase 1 step 2, OPT-IN) ────────────────────────
# Pushes the session's Claude Code memory files (the sibling memory/ dir of the
# transcript) to the user's own rag-api with hash reconciliation, so unified
# recall can serve them ("Claude writes it, reka keeps it"). The trial audit
# measured ~68% of durable knowledge living ONLY in these files.
#   - OPT-IN per project: REKA_MEMORY_SYNC=1 (ADR-006 decision 3: client-data
#     sync is default OFF). Hooks read the CLAUDE CODE env — enable it in the
#     project's .claude/settings.json:  { "env": { "REKA_MEMORY_SYNC": "1" } }
#     (.mcp.json env reaches only the MCP server process, NOT hooks).
#   - Client-side redaction before egress (keys/tokens/passwords/UA phones);
#     the server applies its own net again before embedding.
#   - Never blocks shutdown: every step fail-open, hard wall-clock budget.
reka_memory_sync() {
  [ "${REKA_MEMORY_SYNC:-0}" = "1" ] || return 0
  command -v jq >/dev/null 2>&1 || { reka_log "memory-sync SKIP: no jq"; return 0; }
  command -v sha256sum >/dev/null 2>&1 || { reka_log "memory-sync SKIP: no sha256sum"; return 0; }
  [ -n "$TRANSCRIPT_PATH" ] || { reka_log "memory-sync SKIP: no transcript_path"; return 0; }

  local mem_dir; mem_dir="$(dirname "$TRANSCRIPT_PATH")/memory"
  [ -d "$mem_dir" ] || { reka_log "memory-sync SKIP: no memory dir ($mem_dir)"; return 0; }

  local budget="${REKA_MEMORY_SYNC_BUDGET_SEC:-30}"
  local started; started="$(date +%s 2>/dev/null || echo 0)"

  # Server manifest: slug -> hash (single fetch; empty on first sync/404).
  local manifest
  manifest="$(curl -fsS -m 5 "$API_URL/api/memory-files"     -H "Authorization: Bearer $API_KEY"     -H "X-Project-Name: $PROJECT" 2>/dev/null || printf '{}')"

  local pushed=0 unchanged=0 failed=0 total=0
  local cap="${REKA_MEMORY_SYNC_MAX_FILES:-10}"
  # Freshest first so a budget cut-off still ships what this session touched.
  local f slug hash srv_hash mtime body
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    total=$((total + 1))
    [ "$pushed" -lt "$cap" ] || continue
    local now; now="$(date +%s 2>/dev/null || echo 0)"
    if [ "$now" -gt 0 ] && [ "$started" -gt 0 ] && [ $((now - started)) -ge "$budget" ]; then
      reka_log "memory-sync STOP: budget ${budget}s hit (pushed=$pushed of $total)"
      break
    fi
    slug="$(basename "$f")"
    hash="$(sha256sum "$f" 2>/dev/null | cut -d' ' -f1)"
    [ -n "$hash" ] || continue
    srv_hash="$(printf '%s' "$manifest" | jq -r --arg s "$slug"       '(.files // [])[] | select(.slug == $s) | .hash' 2>/dev/null | head -1)"
    if [ "$srv_hash" = "$hash" ]; then unchanged=$((unchanged + 1)); continue; fi
    # File mtime, ISO-8601 (GNU date).
    mtime="$(date -u -Iseconds -r "$f" 2>/dev/null || date -u -Iseconds)"
    # Client-side redaction (rules in lib/redact.sed; server net re-applies).
    body="$(sed -E -f "$HOOK_DIR/lib/redact.sed" "$f" 2>/dev/null \
      | jq -Rs --arg slug "$slug" --arg hash "$hash" --arg mtime "$mtime" \
        '{files: [{slug: $slug, hash: $hash, modified: $mtime, content: .}]}' 2>/dev/null)"
    [ -n "$body" ] || { failed=$((failed + 1)); continue; }
    if printf '%s' "$body" | curl -fsS -m 8 -X POST "$API_URL/api/memory-files/sync"         -H "Content-Type: application/json"         -H "Authorization: Bearer $API_KEY"         -H "X-Project-Name: $PROJECT"         --data-binary @- >/dev/null 2>&1; then
      pushed=$((pushed + 1))
    else
      failed=$((failed + 1))
    fi
  done < <(ls -1t "$mem_dir"/*.md 2>/dev/null)

  # Prune: server slugs whose local file is gone (deleted/renamed). Guarded —
  # only when the local dir is non-empty (a wrong dir must never mass-delete)
  # and capped at 20 slugs per run.
  local del_slugs
  del_slugs="$(printf '%s' "$manifest" | jq -r --arg dir "$mem_dir" \
    '(.files // [])[].slug' 2>/dev/null | while IFS= read -r sslug; do
      [ -n "$sslug" ] && [ ! -f "$mem_dir/$sslug" ] && printf '%s\n' "$sslug"
    done | head -20)"
  if [ -n "$del_slugs" ] && [ "$total" -gt 0 ]; then
    local del_body
    del_body="$(printf '%s' "$del_slugs" | jq -Rs '{deleted: (split("\n") | map(select(. != "")))}' 2>/dev/null)"
    if [ -n "$del_body" ]; then
      printf '%s' "$del_body" | curl -fsS -m 8 -X POST "$API_URL/api/memory-files/sync" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $API_KEY" \
        -H "X-Project-Name: $PROJECT" \
        --data-binary @- >/dev/null 2>&1 \
        && reka_log "memory-sync PRUNE: $(printf '%s' "$del_slugs" | grep -c .) server slugs without local files" \
        || true
    fi
  fi

  reka_log "memory-sync OK: pushed=$pushed unchanged=$unchanged failed=$failed total=$total (project=$PROJECT)"
  return 0
}
# ── End RAG session ──────────────────────────────────────────────────────────
# /end is the critical signal — it runs BEFORE the (opt-in) memory sync so a
# slow sync can never starve it inside the hook timeout (review 2026-08-20).
END_SKIPPED=0
if [[ -z "$SESSION_ID" ]]; then
  reka_log "session-end SKIP: no RAG session for cc=${CC_SESSION_ID:-none} (project=$PROJECT)"
  END_SKIPPED=1
fi
if [[ "$END_SKIPPED" -eq 0 ]]; then

# State dir for "already ended" markers. Default to the XDG state dir so the
# marker survives WSL /tmp wipes; honor RAG_STATE_DIR / TMPDIR overrides.
STATE_DIR="${RAG_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/reka}"
MARKER="$STATE_DIR/session-${SESSION_ID}.ended"

# Idempotency: if a marker already exists, this session was ended by an explicit
# /reka:end or an earlier hook run — skip silently. (There is a small TOCTOU
# window between this check and the touch below; the /api/session/:id/end route
# is idempotent server-side, which is the backstop for a concurrent double-fire.)
if [[ -f "$MARKER" ]]; then
  reka_log "session-end SKIP: already ended session=$SESSION_ID"
  END_SKIPPED=2
fi
if [[ "$END_SKIPPED" -eq 0 ]]; then

# End session with autoSaveLearnings — triggers consolidation agent server-side.
# No projectName in the body (enforceProjectScope); the tenant rides the header.
# -m12 keeps capture(-m10) + end(-m12) under the SessionEnd hook timeout (25s).
END_RC=0
curl -fsS -m 12 -X POST "$API_URL/api/session/$SESSION_ID/end" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $API_KEY" \
  -H "X-Project-Name: $PROJECT" \
  -d '{"summary":"Session ended by reka plugin SessionEnd hook","autoSaveLearnings":true}' \
  >/dev/null 2>&1 || END_RC=$?
if [[ "$END_RC" -eq 0 ]]; then
  reka_log "session-end OK: session=$SESSION_ID project=$PROJECT cc=${CC_SESSION_ID:-none}"
else
  reka_log "session-end FAIL: rc=$END_RC session=$SESSION_ID url=$API_URL project=$PROJECT"
fi

# Record the marker so subsequent invocations (or a later /reka:end) no-op.
mkdir -p "$STATE_DIR" 2>/dev/null || true
touch "$MARKER" 2>/dev/null || true
type reka_map_delete >/dev/null 2>&1 && reka_map_delete "$CC_SESSION_ID"
fi
fi

# ── Memory-file sync (opt-in) — after /end, never starving it ────────────────
reka_memory_sync || true

# ── State-dir GC ─────────────────────────────────────────────────────────────
# Per-session stamps/maps/markers accumulate one file per session; sweep
# anything older than 7 days (cheap, best-effort).
GC_DIR="${RAG_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/reka}"
find "$GC_DIR" -maxdepth 2 \( -name 'recall-*.stamp' -o -name 'session-*.ended' \) -mtime +7 -delete 2>/dev/null || true
find "$GC_DIR/sessions" -maxdepth 1 -type f -mtime +7 -delete 2>/dev/null || true

exit 0
