#!/bin/bash
# Tests for the 0.7.0 hook fixes (trial-audit RC1/RC2/RC4):
#   (1) project .mcp.json key+url win over user-scope CLAUDE_PLUGIN_OPTION_* (RC1)
#   (2) userConfig key is still the fallback when no .mcp.json exists
#   (3) prompt-recall skips synthetic prompts (<task-notification> etc.) (RC4)
#   (4) prompt-recall truncates the query to REKA_RECALL_MAX_QUERY (RC4/400s)
#   (5) session-start writes the CC->RAG session map; prompt-recall reads it and
#       sends sessionId; session-end POSTs /end via the map and deletes it (RC2)
#   (6) throttle stamp is per-CC-session, never the shared "nosess" (RC2)
#
# Run: bash tests/hooks-linkage.test.sh  (requires jq)

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SS="$SCRIPT_DIR/../hooks/scripts/session-start.sh"
PR="$SCRIPT_DIR/../hooks/scripts/prompt-recall.sh"
SE="$SCRIPT_DIR/../hooks/scripts/session-end.sh"
LIB="$SCRIPT_DIR/../hooks/scripts/lib/rag-env.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP - jq not available"; exit 0; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()   { echo "ok   - $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL - $1"; FAIL=$((FAIL + 1)); }

# curl shim: logs argv, answers session/start, digest, recall, end.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/curl" <<'SHIM'
#!/bin/bash
echo "$@" >> "${MOCK_LOG:?}"
url=""; for a in "$@"; do case "$a" in http*) url="$a" ;; esac; done
case "$url" in
  */api/session/start*) printf '%s' '{"session":{"sessionId":"rag-777","projectName":"projA"}}' ;;
  */api/session/digest*) printf '%s' '' ;;
  */api/session/*/end*) printf '%s' '{"ok":true}' ;;
  */api/memory/recall*) printf '%s' '{"results":[{"memory":{"content":"mapped recall hit"},"score":0.9}]}' ;;
  *) exit 1 ;;
esac
SHIM
chmod +x "$TMP/bin/curl"

# Project dir with its own .mcp.json (key projA @ mock-a)
mkdir -p "$TMP/projA"
cat > "$TMP/projA/.mcp.json" <<'J'
{"mcpServers":{"a":{"env":{"REKA_API_KEY":"rk_projA_aaaa00","RAG_API_URL":"http://mock-a:3100"}}}}
J
mkdir -p "$TMP/empty"

# ── (1) precedence: .mcp.json beats user-scope plugin option ────────────────
unset RAG_API_KEY RAG_API_URL REKA_PROJECT 2>/dev/null || true
OUT="$(env -i HOME="$TMP" PATH="$TMP/bin:/usr/bin:/bin" \
  CLAUDE_PROJECT_DIR="$TMP/projA" \
  CLAUDE_PLUGIN_OPTION_RAG_API_KEY="rk_userwide_ffff00" \
  CLAUDE_PLUGIN_OPTION_RAG_API_URL="http://userwide:3100" \
  bash -c ". '$LIB'; reka_resolve; echo \"\$RAG_API_KEY \$RAG_API_URL \$REKA_PROJECT\"")"
case "$OUT" in
  "rk_projA_aaaa00 http://mock-a:3100 projA") ok "(1) .mcp.json key+url pair beats user-scope option" ;;
  *) fail "(1) .mcp.json key+url pair beats user-scope option (got: $OUT)" ;;
esac

# ── (2) fallback: no .mcp.json -> user-scope option still used ──────────────
OUT="$(env -i HOME="$TMP" PATH="$TMP/bin:/usr/bin:/bin" \
  CLAUDE_PROJECT_DIR="$TMP/empty" \
  CLAUDE_PLUGIN_OPTION_RAG_API_KEY="rk_userwide_ffff00" \
  CLAUDE_PLUGIN_OPTION_RAG_API_URL="http://userwide:3100" \
  bash -c ". '$LIB'; reka_resolve; echo \"\$RAG_API_KEY \$RAG_API_URL \$REKA_PROJECT\"")"
case "$OUT" in
  "rk_userwide_ffff00 http://userwide:3100 userwide") ok "(2) userConfig fallback without .mcp.json" ;;
  *) fail "(2) userConfig fallback without .mcp.json (got: $OUT)" ;;
esac

run_pr() { # run_pr <prompt-json-file> [env...]
  local f="$1"; shift
  OUT=$(cat "$f" | env PATH="$TMP/bin:$PATH" MOCK_LOG="$MOCK_LOG" \
      CLAUDE_PROJECT_DIR="$TMP/projA" RAG_STATE_DIR="$STATE" \
      "$@" bash "$PR" 2>/dev/null)
  RC=$?
}

# ── (3) synthetic prompts skipped ───────────────────────────────────────────
STATE="$(mktemp -d)"; MOCK_LOG="$TMP/log3"; : > "$MOCK_LOG"
for p in '<task-notification>\nlong body here padding padding padding' \
         '<bash-input>ls -la some directory listing padding padding' \
         '[Request interrupted by user for tool use padding padding'; do
  printf '{"prompt":"%s","session_id":"cc-syn"}' "$p" | jq -c . >/dev/null 2>&1 || true
  jq -nc --arg p "$(printf '%b' "$p")" '{prompt:$p,session_id:"cc-syn"}' > "$TMP/in3.json"
  run_pr "$TMP/in3.json"
done
if [ ! -s "$MOCK_LOG" ]; then ok "(3) synthetic prompts -> no curl at all"; else fail "(3) synthetic prompts -> no curl (log: $(cat "$MOCK_LOG"))"; fi

# ── (4) long prompt truncated to 1500 (default) ─────────────────────────────
STATE="$(mktemp -d)"; MOCK_LOG="$TMP/log4"; : > "$MOCK_LOG"
LONG="$(printf 'q%.0s' $(seq 1 6000))"
jq -nc --arg p "$LONG" '{prompt:$p,session_id:"cc-trunc"}' > "$TMP/in4.json"
run_pr "$TMP/in4.json"
QLEN="$(grep -o '"query":"[^"]*"' "$MOCK_LOG" | head -1 | wc -c)"
if [ "$QLEN" -gt 1400 ] && [ "$QLEN" -lt 1600 ]; then ok "(4) query truncated to ~1500 (${QLEN}b)"; else fail "(4) query truncated to ~1500 (got ${QLEN}b)"; fi

# ── (5) session map end-to-end: start -> recall(sessionId) -> end -> unmap ──
STATE="$(mktemp -d)"; MOCK_LOG="$TMP/log5"; : > "$MOCK_LOG"
printf '{"session_id":"cc-e2e","source":"startup"}' \
  | env PATH="$TMP/bin:$PATH" MOCK_LOG="$MOCK_LOG" \
      CLAUDE_PROJECT_DIR="$TMP/projA" RAG_STATE_DIR="$STATE" \
      bash "$SS" >/dev/null 2>&1
MAP="$STATE/sessions/cc-e2e"
if [ -f "$MAP" ] && grep -q "rag-777" "$MAP"; then ok "(5a) session-start wrote map cc-e2e -> rag-777"; else fail "(5a) map missing (state: $(ls -R "$STATE" 2>/dev/null))"; fi

jq -nc '{prompt:"please refactor the retry logic in the indexer service",session_id:"cc-e2e"}' > "$TMP/in5.json"
run_pr "$TMP/in5.json"
RECALL_LINE="$(grep 'api/memory/recall' "$MOCK_LOG" | head -1)"
case "$RECALL_LINE" in
  *'"sessionId":"rag-777"'*) ok "(5b) prompt-recall sends mapped sessionId" ;;
  *) fail "(5b) prompt-recall sends mapped sessionId (got: $RECALL_LINE)" ;;
esac
[ -f "$STATE/recall-rag-777.stamp" ] && ok "(5c) throttle stamp keyed by RAG session" || fail "(5c) throttle stamp keyed by RAG session ($(ls "$STATE"))"

printf '{"session_id":"cc-e2e","transcript_path":"/nonexistent"}' \
  | env PATH="$TMP/bin:$PATH" MOCK_LOG="$MOCK_LOG" \
      CLAUDE_PROJECT_DIR="$TMP/projA" RAG_STATE_DIR="$STATE" REKA_TRANSCRIPT_CAPTURE=0 \
      bash "$SE" >/dev/null 2>&1
END_LINE="$(grep 'session/rag-777/end' "$MOCK_LOG" | head -1)"
if [ -n "$END_LINE" ]; then ok "(5d) session-end POSTs /end for the mapped session"; else fail "(5d) /end not called (log: $(tail -3 "$MOCK_LOG"))"; fi
[ ! -f "$MAP" ] && ok "(5e) map deleted after end" || fail "(5e) map deleted after end"
[ -f "$STATE/session-rag-777.ended" ] && ok "(5f) .ended marker written" || fail "(5f) .ended marker written"

# ── (6) no map, no RAG session -> per-CC-session stamp (not nosess) ─────────
STATE="$(mktemp -d)"; MOCK_LOG="$TMP/log6"; : > "$MOCK_LOG"
jq -nc '{prompt:"investigate why the payment webhook retries forever",session_id:"cc-solo"}' > "$TMP/in6.json"
run_pr "$TMP/in6.json"
[ -f "$STATE/recall-cc-solo.stamp" ] && ok "(6) stamp keyed by CC session id" || fail "(6) stamp keyed by CC session id ($(ls "$STATE"))"
[ ! -f "$STATE/recall-nosess.stamp" ] && ok "(6b) no shared nosess stamp" || fail "(6b) no shared nosess stamp"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
