#!/bin/bash
# SessionStart hook: auto-start a RAG session, inject env vars for the later
# hooks, and emit the session digest to stdout (Claude Code injects
# SessionStart-hook stdout into context — guaranteed delivery beats retrieval).
#
# Config resolves durably via lib/rag-env.sh: userConfig first, then the
# project's own .mcp.json key (the sensitive userConfig key is dropped on
# restart — CC #62442). The project NAMESPACE is derived from the key and
# carried only in the X-Project-Name header (which the server overwrites from
# the key); we never send a client-chosen projectName in the body/query — the
# server's enforceProjectScope 403s a mismatched projectName on a keyed project.
#
# On any failure: exit 0 silently (fallback: ensureSession() in MCP middleware).
# Dependencies: curl (standard). jq optional (sed fallback in rag-env.sh).

set -euo pipefail

# Explicit-empty userConfig URL = kill switch (disable the hook entirely).
if [ "${CLAUDE_PLUGIN_OPTION_RAG_API_URL+set}" = "set" ] && [ -z "${CLAUDE_PLUGIN_OPTION_RAG_API_URL}" ]; then
  exit 0
fi

# Resolve RAG_API_URL / RAG_API_KEY / REKA_PROJECT.
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/rag-env.sh
. "$HOOK_DIR/lib/rag-env.sh" 2>/dev/null || exit 0
reka_resolve

if [ -z "$RAG_API_URL" ]; then
  exit 0
fi

# Header tenant: the key's namespace when keyed, else 'default' for the
# anonymous/dev path. The server overwrites this from the key for keyed
# requests; for anonymous it is used as-is.
PROJECT_HEADER="${REKA_PROJECT:-default}"

# Start session. No projectName in the body — the server resolves the namespace
# from the key (or the header for anonymous), and validateProjectName reads the
# X-Project-Name header first.
RESPONSE=$(curl -s -m 5 -X POST "$RAG_API_URL/api/session/start" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $RAG_API_KEY" \
  -H "X-Project-Name: $PROJECT_HEADER" \
  -d '{"initialContext":"auto-started by reka plugin SessionStart hook"}' \
  2>/dev/null || echo "")

if [ -z "$RESPONSE" ]; then
  exit 0
fi

# Parse the created sessionId + the server's authoritative projectName.
if command -v jq &>/dev/null; then
  SESSION_ID=$(echo "$RESPONSE" | jq -r '.session.sessionId // .sessionId // empty' 2>/dev/null || echo "")
  RESOLVED_PROJECT=$(echo "$RESPONSE" | jq -r '.session.projectName // empty' 2>/dev/null || echo "")
else
  SESSION_ID=$(echo "$RESPONSE" | sed -n 's/.*"sessionId"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  RESOLVED_PROJECT=$(echo "$RESPONSE" | sed -n 's/.*"projectName"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
fi

# Downstream hooks use the server's authoritative project; fall back to the
# key-derived header value.
PROJECT="${RESOLVED_PROJECT:-$PROJECT_HEADER}"

# Inject env vars for the later hooks (session-end, prompt-recall) + tools.
# %q shell-quotes each value so that sourcing the env file assigns the literal
# string — a .mcp.json key (or server response) carrying shell metacharacters
# cannot execute when Claude Code sources this file. The `|| true` keeps a
# write failure (disk full / perms) from aborting the hook under set -e.
if [ -n "$SESSION_ID" ] && [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  {
    printf 'export RAG_SESSION_ID=%q\n'   "$SESSION_ID"
    printf 'export RAG_PROJECT_NAME=%q\n' "$PROJECT"
    printf 'export RAG_API_URL=%q\n'      "$RAG_API_URL"
    printf 'export RAG_API_KEY=%q\n'      "$RAG_API_KEY"
  } >> "$CLAUDE_ENV_FILE" 2>/dev/null || true
fi

# Fetch the digest and emit it to stdout for context injection. sessionId-only
# query (no projectName — enforceProjectScope checks query.projectName; the
# tenant rides the header). The body IS the markdown digest (no jq needed).
# Fail-silent: -f drops HTTP-error bodies, any failure -> no output, exit 0.
if [ -n "$SESSION_ID" ]; then
  DIGEST=$(curl -fs -m 5 \
    "$RAG_API_URL/api/session/digest?sessionId=$SESSION_ID" \
    -H "Authorization: Bearer $RAG_API_KEY" \
    -H "X-Project-Name: $PROJECT" \
    2>/dev/null || echo "")
  if [ -n "$DIGEST" ]; then
    echo "$DIGEST"
  fi
fi

exit 0
