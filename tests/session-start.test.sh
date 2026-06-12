#!/bin/bash
# Smoke test for hooks/scripts/session-start.sh (plain bash, no harness).
# Mocks curl via a PATH shim and asserts:
#   (a) digest markdown is passed through to stdout on 200
#   (b) silent exit 0 on digest failure/timeout and on session-start failure
#   (c) no output (and no curl call) when RAG_API_URL is explicitly unset
#
# Run: bash tests/session-start.test.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/scripts/session-start.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── curl shim ────────────────────────────────────────────────────────────────
# Logs every invocation to $MOCK_LOG; behavior selected via $MOCK_MODE.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/curl" <<'SHIM'
#!/bin/bash
echo "$@" >> "${MOCK_LOG:?}"
url=""
for a in "$@"; do case "$a" in http*) url="$a" ;; esac; done
case "$url" in
  */api/session/start*)
    if [ "${MOCK_MODE:-ok}" = "start_fail" ]; then exit 7; fi
    printf '%s' '{"success":true,"session":{"sessionId":"sess-123"}}'
    ;;
  */api/session/digest*)
    case "${MOCK_MODE:-ok}" in
      ok) printf '# Session Digest\n- pinned: npm 10 lockfiles only\n' ;;
      digest_timeout) exit 28 ;;     # curl: operation timed out (-m)
      digest_http_error) exit 22 ;;  # curl -f on HTTP >= 400: no body, exit 22
    esac
    ;;
  *) exit 1 ;;
esac
SHIM
chmod +x "$TMP/bin/curl"

PASS=0
FAIL=0
ok()   { echo "ok   - $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL - $1"; FAIL=$((FAIL + 1)); }

run_hook() {
  # run_hook <mock_mode> [extra env VAR=VAL ...]; stdout -> $OUT, exit -> $RC
  local mode="$1"; shift
  OUT=$(env PATH="$TMP/bin:$PATH" \
    MOCK_MODE="$mode" MOCK_LOG="$MOCK_LOG" \
    CLAUDE_PLUGIN_OPTION_PROJECT_NAME="testproj" \
    CLAUDE_PLUGIN_OPTION_RAG_API_KEY="test-key" \
    "$@" bash "$HOOK" 2>/dev/null)
  RC=$?
}

# ── (a) digest stdout passthrough on 200 ────────────────────────────────────
MOCK_LOG="$TMP/log-a"; : > "$MOCK_LOG"
run_hook ok CLAUDE_PLUGIN_OPTION_RAG_API_URL="http://mock:3100"
[ "$RC" -eq 0 ] && ok "(a) exit 0 on success" || fail "(a) exit 0 on success (got $RC)"
case "$OUT" in
  *"# Session Digest"*"pinned: npm 10 lockfiles only"*) ok "(a) digest markdown on stdout" ;;
  *) fail "(a) digest markdown on stdout (got: $OUT)" ;;
esac
if grep -q "api/session/digest?projectName=testproj&sessionId=sess-123" "$MOCK_LOG"; then
  ok "(a) digest GET carries projectName + the created sessionId"
else
  fail "(a) digest GET carries projectName + the created sessionId"
fi
if grep "api/session/digest" "$MOCK_LOG" | grep -q "Bearer test-key"; then
  ok "(a) digest GET reuses the Bearer auth header"
else
  fail "(a) digest GET reuses the Bearer auth header"
fi

# ── (b) silent exit 0 on failure/timeout ────────────────────────────────────
MOCK_LOG="$TMP/log-b1"; : > "$MOCK_LOG"
run_hook digest_timeout CLAUDE_PLUGIN_OPTION_RAG_API_URL="http://mock:3100"
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok "(b) digest timeout: exit 0, no output" \
  || fail "(b) digest timeout: exit 0, no output (rc=$RC out=$OUT)"

MOCK_LOG="$TMP/log-b2"; : > "$MOCK_LOG"
run_hook digest_http_error CLAUDE_PLUGIN_OPTION_RAG_API_URL="http://mock:3100"
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok "(b) digest HTTP error: exit 0, no output" \
  || fail "(b) digest HTTP error: exit 0, no output (rc=$RC out=$OUT)"

MOCK_LOG="$TMP/log-b3"; : > "$MOCK_LOG"
run_hook start_fail CLAUDE_PLUGIN_OPTION_RAG_API_URL="http://mock:3100"
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok "(b) session-start failure: exit 0, no output" \
  || fail "(b) session-start failure: exit 0, no output (rc=$RC out=$OUT)"
if grep -q "api/session/digest" "$MOCK_LOG"; then
  fail "(b) no digest call after session-start failure"
else
  ok "(b) no digest call after session-start failure"
fi

# ── (c) no output when RAG_API_URL unset ────────────────────────────────────
MOCK_LOG="$TMP/log-c"; : > "$MOCK_LOG"
run_hook ok CLAUDE_PLUGIN_OPTION_RAG_API_URL=""
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok "(c) RAG_API_URL unset: exit 0, no output" \
  || fail "(c) RAG_API_URL unset: exit 0, no output (rc=$RC out=$OUT)"
if [ -s "$MOCK_LOG" ]; then
  fail "(c) curl never called when RAG_API_URL unset"
else
  ok "(c) curl never called when RAG_API_URL unset"
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
