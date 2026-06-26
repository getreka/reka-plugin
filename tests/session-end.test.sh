#!/bin/bash
# Smoke test for hooks/scripts/session-end.sh (plain bash, no harness).
# Mocks curl via a PATH shim and asserts:
#   (i)   transcript shipped with correct URL/headers/body from hook stdin
#   (ii)  NOT shipped when REKA_TRANSCRIPT_CAPTURE=0
#   (iii) NOT shipped when transcript_path is missing or nonexistent
#   (iv)  capture still runs when the .ended marker exists (end call skipped)
#   (v)   end-session call when RAG_SESSION_ID set and no marker; the tenant
#         rides the X-Project-Name header, NOT a client projectName in the body
#   (vi)  hook always exits 0 even when curl fails
#   (vii) durable key re-resolution from .mcp.json when the env key was dropped
#
# Run: bash tests/session-end.test.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/scripts/session-end.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── curl shim ────────────────────────────────────────────────────────────────
# Logs every invocation to $MOCK_LOG; saves capture-POST stdin to $MOCK_BODY;
# behavior selected via $MOCK_MODE.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/curl" <<'SHIM'
#!/bin/bash
echo "$@" >> "${MOCK_LOG:?}"
url=""
for a in "$@"; do case "$a" in http*) url="$a" ;; esac; done
case "$url" in
  */api/capture/transcript*)
    cat > "${MOCK_BODY:-/dev/null}"
    if [ "${MOCK_MODE:-ok}" = "curl_fail" ]; then exit 7; fi
    printf '%s' '{"success":true}'
    ;;
  */api/session/*/end)
    if [ "${MOCK_MODE:-ok}" = "curl_fail" ]; then exit 7; fi
    printf '%s' '{"success":true}'
    ;;
  *) exit 1 ;;
esac
SHIM
chmod +x "$TMP/bin/curl"

PASS=0
FAIL=0
ok()   { echo "ok   - $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL - $1"; FAIL=$((FAIL + 1)); }

# Transcript fixture (>1 line so --data-binary preservation is meaningful)
TRANSCRIPT="$TMP/transcript.jsonl"
printf '{"type":"user","text":"hello"}\n{"type":"assistant","text":"hi"}\n' > "$TRANSCRIPT"

stdin_json() {
  # stdin_json [transcript_path] — compact hook-input JSON like Claude Code's
  printf '{"session_id":"cc-abc","transcript_path":"%s","cwd":"/x","hook_event_name":"SessionEnd","reason":"exit"}' "${1:-}"
}

run_hook() {
  # run_hook <mock_mode> <stdin_string> [extra env VAR=VAL ...]; exit -> $RC
  # Ambient RAG_*/REKA_* are blanked first (a real reka session exports them);
  # later duplicates in "$@" win, so per-case overrides still apply.
  local mode="$1" input="$2"; shift 2
  OUT=$(printf '%s' "$input" | env PATH="$TMP/bin:$PATH" \
    MOCK_MODE="$mode" MOCK_LOG="$MOCK_LOG" MOCK_BODY="$MOCK_BODY" \
    RAG_API_URL="http://mock:3100" RAG_API_KEY="test-key" \
    RAG_PROJECT_NAME="testproj" \
    RAG_SESSION_ID="" RAG_STATE_DIR="" REKA_TRANSCRIPT_CAPTURE="" \
    "$@" bash "$HOOK" 2>/dev/null)
  RC=$?
}

# ── (i) transcript shipped with correct URL/headers/body ────────────────────
MOCK_LOG="$TMP/log-i"; : > "$MOCK_LOG"; MOCK_BODY="$TMP/body-i"
run_hook ok "$(stdin_json "$TRANSCRIPT")"
[ "$RC" -eq 0 ] && ok "(i) exit 0" || fail "(i) exit 0 (got $RC)"
if grep "api/capture/transcript?sessionId=cc-abc" "$MOCK_LOG" | grep -q -- "-X POST"; then
  ok "(i) POST to capture endpoint keyed on the CC session id"
else
  fail "(i) POST to capture endpoint keyed on the CC session id"
fi
CAPTURE_LINE="$(grep "api/capture/transcript" "$MOCK_LOG" | head -1)"
case "$CAPTURE_LINE" in
  *"Content-Type: text/plain"*"Authorization: Bearer test-key"*"X-Project-Name: testproj"*"--data-binary @-"*)
    ok "(i) capture carries text/plain + auth + project headers, body via stdin" ;;
  *) fail "(i) capture carries text/plain + auth + project headers, body via stdin (got: $CAPTURE_LINE)" ;;
esac
if cmp -s "$MOCK_BODY" "$TRANSCRIPT"; then
  ok "(i) body is the raw transcript content"
else
  fail "(i) body is the raw transcript content"
fi
if grep -q "api/session/.*/end" "$MOCK_LOG"; then
  fail "(i) no end-session call when RAG_SESSION_ID is empty"
else
  ok "(i) no end-session call when RAG_SESSION_ID is empty"
fi

# ── (ii) NOT shipped when REKA_TRANSCRIPT_CAPTURE=0 ─────────────────────────
MOCK_LOG="$TMP/log-ii"; : > "$MOCK_LOG"; MOCK_BODY="$TMP/body-ii"
run_hook ok "$(stdin_json "$TRANSCRIPT")" REKA_TRANSCRIPT_CAPTURE=0
[ "$RC" -eq 0 ] && ok "(ii) exit 0" || fail "(ii) exit 0 (got $RC)"
if grep -q "api/capture/transcript" "$MOCK_LOG"; then
  fail "(ii) opt-out: no capture call"
else
  ok "(ii) opt-out: no capture call"
fi

# ── (iii) NOT shipped when transcript_path missing or nonexistent ───────────
MOCK_LOG="$TMP/log-iii"; : > "$MOCK_LOG"; MOCK_BODY="$TMP/body-iii"
run_hook ok '{"session_id":"cc-abc","hook_event_name":"SessionEnd","reason":"exit"}'
[ "$RC" -eq 0 ] && ok "(iii) exit 0 with no transcript_path key" \
  || fail "(iii) exit 0 with no transcript_path key (got $RC)"
run_hook ok "$(stdin_json "$TMP/does-not-exist.jsonl")"
[ "$RC" -eq 0 ] && ok "(iii) exit 0 with nonexistent path" \
  || fail "(iii) exit 0 with nonexistent path (got $RC)"
run_hook ok ""
[ "$RC" -eq 0 ] && ok "(iii) exit 0 with empty stdin" \
  || fail "(iii) exit 0 with empty stdin (got $RC)"
if grep -q "api/capture/transcript" "$MOCK_LOG"; then
  fail "(iii) no capture call in any of the three cases"
else
  ok "(iii) no capture call in any of the three cases"
fi

# ── (iv) marker exists: capture still runs, end-session skipped ─────────────
MOCK_LOG="$TMP/log-iv"; : > "$MOCK_LOG"; MOCK_BODY="$TMP/body-iv"
STATE_DIR="$TMP/state-iv"; mkdir -p "$STATE_DIR"
touch "$STATE_DIR/session-rag-sess-1.ended"
run_hook ok "$(stdin_json "$TRANSCRIPT")" \
  RAG_SESSION_ID="rag-sess-1" RAG_STATE_DIR="$STATE_DIR"
[ "$RC" -eq 0 ] && ok "(iv) exit 0" || fail "(iv) exit 0 (got $RC)"
if grep -q "api/capture/transcript?sessionId=cc-abc" "$MOCK_LOG"; then
  ok "(iv) capture runs despite the .ended marker"
else
  fail "(iv) capture runs despite the .ended marker"
fi
if grep -q "api/session/rag-sess-1/end" "$MOCK_LOG"; then
  fail "(iv) end-session skipped when marker exists"
else
  ok "(iv) end-session skipped when marker exists"
fi

# ── (v) end-session unchanged when RAG_SESSION_ID set and no marker ─────────
MOCK_LOG="$TMP/log-v"; : > "$MOCK_LOG"; MOCK_BODY="$TMP/body-v"
STATE_DIR="$TMP/state-v"
run_hook ok "$(stdin_json "$TRANSCRIPT")" \
  RAG_SESSION_ID="rag-sess-2" RAG_STATE_DIR="$STATE_DIR"
[ "$RC" -eq 0 ] && ok "(v) exit 0" || fail "(v) exit 0 (got $RC)"
END_LINE="$(grep "api/session/rag-sess-2/end" "$MOCK_LOG" | head -1)"
case "$END_LINE" in
  *"-X POST"*"Content-Type: application/json"*"Bearer test-key"*"X-Project-Name: testproj"*'"autoSaveLearnings":true'*)
    ok "(v) end-session POST with json + auth + autoSaveLearnings" ;;
  *) fail "(v) end-session POST with json + auth + autoSaveLearnings (got: $END_LINE)" ;;
esac
if printf '%s' "$END_LINE" | grep -q '"projectName"'; then
  fail "(v) end body must NOT carry a client projectName (enforceProjectScope)"
else
  ok "(v) end body carries no client projectName (tenant rides the header)"
fi
if [ -f "$STATE_DIR/session-rag-sess-2.ended" ]; then
  ok "(v) .ended marker written after the end call"
else
  fail "(v) .ended marker written after the end call"
fi

# ── (vi) always exit 0 even when curl fails ─────────────────────────────────
MOCK_LOG="$TMP/log-vi"; : > "$MOCK_LOG"; MOCK_BODY="$TMP/body-vi"
STATE_DIR="$TMP/state-vi"
run_hook curl_fail "$(stdin_json "$TRANSCRIPT")" \
  RAG_SESSION_ID="rag-sess-3" RAG_STATE_DIR="$STATE_DIR"
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok "(vi) curl failure: exit 0, no output" \
  || fail "(vi) curl failure: exit 0, no output (rc=$RC out=$OUT)"

# ── (vii) durable .mcp.json key resolution when the env key was dropped ──────
# A restart can drop the session-start-injected RAG_API_KEY (CC #62442); the
# hook must re-resolve from the project's own .mcp.json and still end with the
# right tenant (Bearer + key-derived X-Project-Name).
MCPDIR="$TMP/mcpproj"; mkdir -p "$MCPDIR"
cat > "$MCPDIR/.mcp.json" <<'JSON'
{ "mcpServers": { "rag": { "command": "npx", "args": ["-y","@getreka/mcp@latest"],
  "env": { "RAG_API_URL": "http://mock:3100", "REKA_API_KEY": "rk_mcpproj_beef11" } } } }
JSON
MOCK_LOG="$TMP/log-vii"; : > "$MOCK_LOG"; MOCK_BODY="$TMP/body-vii"
STATE_DIR="$TMP/state-vii"
OUT=$(printf '%s' "$(stdin_json "$TRANSCRIPT")" | env PATH="$TMP/bin:$PATH" \
  MOCK_MODE=ok MOCK_LOG="$MOCK_LOG" MOCK_BODY="$MOCK_BODY" \
  CLAUDE_PROJECT_DIR="$MCPDIR" \
  RAG_API_URL="" RAG_API_KEY="" RAG_PROJECT_NAME="" \
  RAG_SESSION_ID="rag-sess-7" RAG_STATE_DIR="$STATE_DIR" \
  bash "$HOOK" 2>/dev/null); RC=$?
[ "$RC" -eq 0 ] && ok "(vii) durable fallback: exit 0" || fail "(vii) durable fallback: exit 0 (got $RC)"
END_LINE7="$(grep "api/session/rag-sess-7/end" "$MOCK_LOG" | head -1)"
case "$END_LINE7" in
  *"Bearer rk_mcpproj_beef11"*"X-Project-Name: mcpproj"*)
    ok "(vii) end re-resolves key+project from .mcp.json" ;;
  *) fail "(vii) end re-resolves key+project from .mcp.json (got: $END_LINE7)" ;;
esac

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
