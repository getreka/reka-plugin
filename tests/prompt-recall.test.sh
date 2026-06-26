#!/bin/bash
# Smoke test for hooks/scripts/prompt-recall.sh (plain bash, no harness).
# Mocks curl via a PATH shim and asserts the zero-action auto-recall behavior:
#   (a) substantive prompt -> recall POST; markdown block injected to stdout;
#       body carries sessionId + NO client projectName; tenant rides the header
#   (b) slash-command prompt -> skipped (no curl)
#   (c) trivially short prompt -> skipped (no curl)
#   (d) REKA_AUTO_RECALL=0 opt-out -> skipped (no curl)
#   (e) zero results -> no output, but the call was made
#   (f) throttle -> a second call in the window does not curl
#   (g) curl failure -> exit 0, no output
#
# Run: bash tests/prompt-recall.test.sh  (requires jq)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/scripts/prompt-recall.sh"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP - jq not available"; exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/proj"   # empty project dir (no .mcp.json)

# ── curl shim ────────────────────────────────────────────────────────────────
mkdir -p "$TMP/bin"
cat > "$TMP/bin/curl" <<'SHIM'
#!/bin/bash
echo "$@" >> "${MOCK_LOG:?}"
url=""
for a in "$@"; do case "$a" in http*) url="$a" ;; esac; done
case "$url" in
  */api/memory/recall*)
    case "${MOCK_MODE:-ok}" in
      fail)  exit 7 ;;
      empty) printf '%s' '{"results":[]}' ;;
      *)     printf '%s' '{"results":[{"memory":{"content":"Use npm 10 for lockfiles"},"score":0.9},{"memory":{"content":"Qdrant range needs numeric fields"},"score":0.8}]}' ;;
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

run_recall() {
  # run_recall <mock_mode> <prompt> [extra env VAR=VAL ...]; stdout->$OUT exit->$RC
  # Fresh state dir per call (no throttle bleed) unless RECALL_STATE is exported.
  local mode="$1" prompt="$2"; shift 2
  local sd="${RECALL_STATE:-$(mktemp -d)}"
  OUT=$(printf '{"prompt":"%s","session_id":"cc-1"}' "$prompt" \
    | env PATH="$TMP/bin:$PATH" MOCK_MODE="$mode" MOCK_LOG="$MOCK_LOG" \
        CLAUDE_PROJECT_DIR="$TMP/proj" \
        RAG_API_URL="http://mock:3100" RAG_API_KEY="rk_testproj_dead00" \
        RAG_PROJECT_NAME="testproj" RAG_SESSION_ID="rag-s1" \
        RAG_STATE_DIR="$sd" \
        "$@" bash "$HOOK" 2>/dev/null)
  RC=$?
}

# ── (a) substantive prompt -> recall + injected block ───────────────────────
MOCK_LOG="$TMP/log-a"; : > "$MOCK_LOG"
run_recall ok "refactor the indexer to add retry logic"
[ "$RC" -eq 0 ] && ok "(a) exit 0" || fail "(a) exit 0 (got $RC)"
case "$OUT" in
  *"Relevant project memory (auto-recall)"*"Use npm 10 for lockfiles"*)
    ok "(a) recalled memory injected to stdout" ;;
  *) fail "(a) recalled memory injected to stdout (got: $OUT)" ;;
esac
RECALL_LINE="$(grep "api/memory/recall" "$MOCK_LOG" | head -1)"
case "$RECALL_LINE" in
  *'"sessionId":"rag-s1"'*) ok "(a) body carries sessionId (server logs surface=recall)" ;;
  *) fail "(a) body carries sessionId (got: $RECALL_LINE)" ;;
esac
if printf '%s' "$RECALL_LINE" | grep -q '"projectName"'; then
  fail "(a) body must NOT carry a client projectName (enforceProjectScope)"
else
  ok "(a) body carries no client projectName"
fi
case "$RECALL_LINE" in
  *"X-Project-Name: testproj"*) ok "(a) tenant rides the X-Project-Name header" ;;
  *) fail "(a) tenant rides the X-Project-Name header (got: $RECALL_LINE)" ;;
esac
case "$RECALL_LINE" in
  *'"graphRecall":true'*) ok "(a) graphRecall enabled" ;;
  *) fail "(a) graphRecall enabled (got: $RECALL_LINE)" ;;
esac

# ── (b) slash-command prompt -> skipped ─────────────────────────────────────
MOCK_LOG="$TMP/log-b"; : > "$MOCK_LOG"
run_recall ok "/reka:code implement the parser changes here"
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok "(b) slash prompt: exit 0, no output" \
  || fail "(b) slash prompt: exit 0, no output (rc=$RC out=$OUT)"
[ -s "$MOCK_LOG" ] && fail "(b) no curl on slash prompt" || ok "(b) no curl on slash prompt"

# ── (c) trivially short prompt -> skipped ───────────────────────────────────
MOCK_LOG="$TMP/log-c"; : > "$MOCK_LOG"
run_recall ok "fix typo"
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok "(c) short prompt: exit 0, no output" \
  || fail "(c) short prompt: exit 0, no output (rc=$RC out=$OUT)"
[ -s "$MOCK_LOG" ] && fail "(c) no curl on short prompt" || ok "(c) no curl on short prompt"

# ── (d) opt-out -> skipped ──────────────────────────────────────────────────
MOCK_LOG="$TMP/log-d"; : > "$MOCK_LOG"
run_recall ok "refactor the indexer to add retry logic" REKA_AUTO_RECALL=0
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok "(d) opt-out: exit 0, no output" \
  || fail "(d) opt-out: exit 0, no output (rc=$RC out=$OUT)"
[ -s "$MOCK_LOG" ] && fail "(d) no curl when opted out" || ok "(d) no curl when opted out"

# ── (e) zero results -> no output, call still made ──────────────────────────
MOCK_LOG="$TMP/log-e"; : > "$MOCK_LOG"
run_recall empty "trace how authentication flows through the services"
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok "(e) empty results: exit 0, no output" \
  || fail "(e) empty results: exit 0, no output (rc=$RC out=$OUT)"
if grep -q "api/memory/recall" "$MOCK_LOG"; then
  ok "(e) recall call made even when results are empty"
else
  fail "(e) recall call made even when results are empty"
fi

# ── (f) throttle -> second call in the window does not curl ──────────────────
MOCK_LOG="$TMP/log-f"; : > "$MOCK_LOG"
RECALL_STATE="$TMP/state-f"; mkdir -p "$RECALL_STATE"
run_recall ok "refactor the indexer to add retry logic"
FIRST_CALLS=$(grep -c "api/memory/recall" "$MOCK_LOG")
run_recall ok "now wire the retry into the embedding path too"
SECOND_CALLS=$(grep -c "api/memory/recall" "$MOCK_LOG")
unset RECALL_STATE
if [ "$FIRST_CALLS" -eq 1 ] && [ "$SECOND_CALLS" -eq 1 ]; then
  ok "(f) throttle: only the first call curls within the window"
else
  fail "(f) throttle: expected 1 then 1 call (got $FIRST_CALLS then $SECOND_CALLS)"
fi

# ── (g) curl failure -> exit 0, no output ───────────────────────────────────
MOCK_LOG="$TMP/log-g"; : > "$MOCK_LOG"
run_recall fail "refactor the indexer to add retry logic"
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok "(g) curl failure: exit 0, no output" \
  || fail "(g) curl failure: exit 0, no output (rc=$RC out=$OUT)"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
