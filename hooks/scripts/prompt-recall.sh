#!/bin/bash
# UserPromptSubmit hook: on a substantive coding-intent prompt, recall relevant
# project memory and inject it into context BEFORE the model acts — zero user
# action. Claude Code injects UserPromptSubmit exit-0 stdout into the turn's
# context. This is the audit's #1 fix: recall was opt-in and idle (7x/14d) while
# users never invoke /reka:* commands.
#
# Fail-open and quiet: any miss (opt-out, no jq/curl, slash/short prompt, no key,
# throttled, curl error, no hits) -> no output, exit 0. Opt out: REKA_AUTO_RECALL=0.
# Reads RAG_SESSION_ID / RAG_PROJECT_NAME from session-start's env injection;
# re-resolves key/url durably via lib/rag-env.sh.

HOOK_INPUT="$(cat 2>/dev/null || true)"

[ "${REKA_AUTO_RECALL:-1}" = "0" ] && exit 0
command -v jq   >/dev/null 2>&1 || exit 0
command -v curl >/dev/null 2>&1 || exit 0

PROMPT="$(printf '%s' "$HOOK_INPUT" | jq -r '.prompt // empty' 2>/dev/null || true)"
[ -n "$PROMPT" ] || exit 0

# Skip slash-commands (own flow) and trivially short prompts.
case "$PROMPT" in /*) exit 0 ;; esac
[ "${#PROMPT}" -lt 30 ] && exit 0

# Resolve env durably.
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/rag-env.sh
. "$HOOK_DIR/lib/rag-env.sh" 2>/dev/null && reka_resolve || true
# Stay fail-open even if sourcing failed and reka_log is undefined.
type reka_log >/dev/null 2>&1 || reka_log() { :; }

API_URL="${RAG_API_URL:-http://localhost:3100}"
API_KEY="${RAG_API_KEY:-}"
PROJECT="${RAG_PROJECT_NAME:-${REKA_PROJECT:-default}}"
SESSION_ID="${RAG_SESSION_ID:-}"

# Empty key against a keyed remote server is a guaranteed silent 401 (the
# historical 0-firings cause). Anonymous is only a real path on localhost dev.
if [ -z "$API_KEY" ]; then
  case "$API_URL" in
    http://localhost*|http://127.0.0.1*) : ;;
    *) reka_log "prompt-recall SKIP: no API key resolved (url=$API_URL project=$PROJECT cwd=$PWD)"; exit 0 ;;
  esac
fi

# Throttle: at most one auto-recall per REKA_RECALL_THROTTLE_SEC per session.
THROTTLE="${REKA_RECALL_THROTTLE_SEC:-45}"
[[ "$THROTTLE" =~ ^[0-9]+$ ]] || THROTTLE=45
STATE_DIR="${RAG_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/reka}"
mkdir -p "$STATE_DIR" 2>/dev/null || true
STAMP="$STATE_DIR/recall-${SESSION_ID:-nosess}.stamp"
NOW="$(date +%s 2>/dev/null || echo 0)"
if [ -f "$STAMP" ]; then
  LAST="$(cat "$STAMP" 2>/dev/null || echo 0)"
  if [ "$NOW" -gt 0 ] && [ "${LAST:-0}" -gt 0 ] && [ $((NOW - LAST)) -lt "$THROTTLE" ]; then
    exit 0
  fi
fi

# Request body. No projectName in the body — validateProjectName reads the
# X-Project-Name header (overwritten from the key server-side); a mismatched
# body projectName would 403 (enforceProjectScope). sessionId makes the server
# log retrieval surface='recall' (the measurable signal).
BODY="$(jq -nc --arg q "$PROMPT" --argjson lim 3 --arg s "$SESSION_ID" \
  '{query:$q, graphRecall:true, limit:$lim} + (if $s=="" then {} else {sessionId:$s} end)' \
  2>/dev/null || true)"
[ -n "$BODY" ] || exit 0

# -m 8: graph recall over a remote HTTPS server routinely exceeds the old -m 3
# (session-start uses -m 5 for a cheaper call). Stays inside the hook's 10s cap.
CURL_ERR=""
RESP="$(curl -fsS -m 8 -X POST "$API_URL/api/memory/recall" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $API_KEY" \
  -H "X-Project-Name: $PROJECT" \
  -d "$BODY" 2>&1)" || CURL_ERR="rc=$?"
if [ -n "$CURL_ERR" ] || [ -z "$RESP" ]; then
  reka_log "prompt-recall FAIL: $CURL_ERR url=$API_URL project=$PROJECT resp=$(printf '%s' "$RESP" | head -c 160)"
  exit 0
fi

# A successful call counts against the throttle even if it returned no hits —
# otherwise a memory-less project (a common early state) re-curls every prompt.
printf '%s' "$NOW" > "$STAMP" 2>/dev/null || true

# Format up to 3 memory contents as a markdown block.
BLOCK="$(printf '%s' "$RESP" | jq -r '
  (.results // [])[:3]
  | map("- " + ((.memory.content // "") | gsub("[\n\r]+";" ") | .[0:280]))
  | if length > 0 then "## Relevant project memory (auto-recall)\n" + join("\n") else empty end
' 2>/dev/null || true)"

if [ -n "$BLOCK" ]; then
  reka_log "prompt-recall OK: injected block (project=$PROJECT session=${SESSION_ID:-none})"
  printf '%s\n' "$BLOCK"
else
  reka_log "prompt-recall OK: no hits (project=$PROJECT)"
fi

exit 0
