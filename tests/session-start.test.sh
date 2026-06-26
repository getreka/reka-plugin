#!/bin/bash
# Smoke test for hooks/scripts/session-start.sh (plain bash, no harness).
# Mocks curl via a PATH shim and asserts the ADR-005 namespace behavior:
#   (a) digest markdown passthrough; the key-derived project rides the header;
#       NO client projectName in the start body or the digest query
#   (b) silent exit 0 on digest/start failure & timeout
#   (c) explicit-empty userConfig URL = kill switch (no curl)
#   (d) durable .mcp.json key fallback when the userConfig key is absent
#   (e) anonymous path (no key) still starts with a 'default' header
#
# Run: bash tests/session-start.test.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/scripts/session-start.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/proj"   # empty project dir (no .mcp.json) for the default cases

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
    printf '%s' '{"success":true,"session":{"sessionId":"sess-123","projectName":"testproj"}}'
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
  # run_hook <mock_mode> [extra env VAR=VAL ...]; stdout -> $OUT, exit -> $RC.
  # Default identity: a realistic key rk_testproj_* -> derived project "testproj".
  local mode="$1"; shift
  OUT=$(env PATH="$TMP/bin:$PATH" \
    MOCK_MODE="$mode" MOCK_LOG="$MOCK_LOG" \
    CLAUDE_PROJECT_DIR="$TMP/proj" \
    CLAUDE_PLUGIN_OPTION_RAG_API_KEY="rk_testproj_dead00" \
    "$@" bash "$HOOK" 2>/dev/null)
  RC=$?
}

# ── (a) digest passthrough + namespace-from-key ─────────────────────────────
MOCK_LOG="$TMP/log-a"; : > "$MOCK_LOG"
run_hook ok CLAUDE_PLUGIN_OPTION_RAG_API_URL="http://mock:3100"
[ "$RC" -eq 0 ] && ok "(a) exit 0 on success" || fail "(a) exit 0 on success (got $RC)"
case "$OUT" in
  *"# Session Digest"*"pinned: npm 10 lockfiles only"*) ok "(a) digest markdown on stdout" ;;
  *) fail "(a) digest markdown on stdout (got: $OUT)" ;;
esac
if grep -q "api/session/digest?sessionId=sess-123" "$MOCK_LOG"; then
  ok "(a) digest GET carries the created sessionId"
else
  fail "(a) digest GET carries the created sessionId"
fi
if grep "api/session/digest" "$MOCK_LOG" | grep -q "projectName"; then
  fail "(a) digest GET must NOT carry a client projectName (enforceProjectScope)"
else
  ok "(a) digest GET carries no client projectName"
fi
if grep -q "X-Project-Name: testproj" "$MOCK_LOG"; then
  ok "(a) requests carry the key-derived project in the header"
else
  fail "(a) requests carry the key-derived project in the header"
fi
if grep "api/session/start" "$MOCK_LOG" | grep -q '"projectName"'; then
  fail "(a) start body must NOT carry a client projectName"
else
  ok "(a) start body carries no client projectName"
fi
if grep "api/session/digest" "$MOCK_LOG" | grep -q "Bearer rk_testproj_dead00"; then
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

# ── (c) explicit-empty userConfig URL = kill switch ─────────────────────────
MOCK_LOG="$TMP/log-c"; : > "$MOCK_LOG"
run_hook ok CLAUDE_PLUGIN_OPTION_RAG_API_URL=""
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok "(c) empty URL kill switch: exit 0, no output" \
  || fail "(c) empty URL kill switch: exit 0, no output (rc=$RC out=$OUT)"
if [ -s "$MOCK_LOG" ]; then
  fail "(c) curl never called when URL explicitly empty"
else
  ok "(c) curl never called when URL explicitly empty"
fi

# ── (d) durable .mcp.json key fallback ──────────────────────────────────────
# userConfig key absent; the project's own .mcp.json provides REKA_API_KEY.
MCPDIR="$TMP/mcpproj"; mkdir -p "$MCPDIR"
cat > "$MCPDIR/.mcp.json" <<'JSON'
{ "mcpServers": { "rag": { "command": "npx", "args": ["-y","@getreka/mcp@latest"],
  "env": { "RAG_API_URL": "http://mock:3100", "REKA_API_KEY": "rk_mcpproj_beef11" } } } }
JSON
MOCK_LOG="$TMP/log-d"; : > "$MOCK_LOG"
OUT=$(env PATH="$TMP/bin:$PATH" MOCK_MODE=ok MOCK_LOG="$MOCK_LOG" \
  CLAUDE_PROJECT_DIR="$MCPDIR" bash "$HOOK" 2>/dev/null); RC=$?
[ "$RC" -eq 0 ] && ok "(d) .mcp.json fallback: exit 0" || fail "(d) .mcp.json fallback: exit 0 (got $RC)"
if grep -q "Bearer rk_mcpproj_beef11" "$MOCK_LOG"; then
  ok "(d) key resolved from .mcp.json when userConfig absent"
else
  fail "(d) key resolved from .mcp.json when userConfig absent"
fi
if grep "api/session/start" "$MOCK_LOG" | grep -q "X-Project-Name: mcpproj"; then
  ok "(d) project derived from the .mcp.json key"
else
  fail "(d) project derived from the .mcp.json key"
fi

# ── (e) anonymous path (no key anywhere) ────────────────────────────────────
MOCK_LOG="$TMP/log-e"; : > "$MOCK_LOG"
OUT=$(env PATH="$TMP/bin:$PATH" MOCK_MODE=ok MOCK_LOG="$MOCK_LOG" \
  CLAUDE_PROJECT_DIR="$TMP/proj" \
  CLAUDE_PLUGIN_OPTION_RAG_API_URL="http://mock:3100" bash "$HOOK" 2>/dev/null); RC=$?
[ "$RC" -eq 0 ] && ok "(e) anonymous: exit 0" || fail "(e) anonymous: exit 0 (got $RC)"
if grep "api/session/start" "$MOCK_LOG" | grep -q "X-Project-Name: default"; then
  ok "(e) anonymous start uses the 'default' header"
else
  fail "(e) anonymous start uses the 'default' header"
fi

# ── (f) CLAUDE_ENV_FILE injection is neutralized by %q quoting ───────────────
# A crafted .mcp.json key carrying shell metacharacters must be written as a
# literal — sourcing the generated env file must NOT execute it (RCE guard).
EVILDIR="$TMP/evil"; mkdir -p "$EVILDIR"
cat > "$EVILDIR/.mcp.json" <<'JSON'
{ "mcpServers": { "rag": { "command": "npx", "args": ["-y","@getreka/mcp@latest"],
  "env": { "RAG_API_URL": "http://mock:3100", "REKA_API_KEY": "rk_evil_x; touch SENTINEL #" } } } }
JSON
ENVF="$TMP/envfile"; : > "$ENVF"
rm -f "$TMP/SENTINEL"
MOCK_LOG="$TMP/log-f"; : > "$MOCK_LOG"
( cd "$TMP" && env PATH="$TMP/bin:$PATH" MOCK_MODE=ok MOCK_LOG="$MOCK_LOG" \
    CLAUDE_PROJECT_DIR="$EVILDIR" CLAUDE_ENV_FILE="$ENVF" \
    bash "$HOOK" >/dev/null 2>&1 ); RC=$?
[ "$RC" -eq 0 ] && ok "(f) injection key: hook exits 0" || fail "(f) injection key: hook exits 0 (got $RC)"
# Source the generated env file in a clean subshell; the injected command must
# not run, and RAG_API_KEY must equal the literal value.
KEYVAL="$( cd "$TMP" && set +u; . "$ENVF" >/dev/null 2>&1; printf '%s' "${RAG_API_KEY:-}" )"
if [ -e "$TMP/SENTINEL" ]; then
  fail "(f) injected command EXECUTED when env file sourced (RCE)"
else
  ok "(f) injected command neutralized (no SENTINEL)"
fi
if [ "$KEYVAL" = 'rk_evil_x; touch SENTINEL #' ]; then
  ok "(f) key assigned as the literal string"
else
  fail "(f) key literal mismatch (got: $KEYVAL)"
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
