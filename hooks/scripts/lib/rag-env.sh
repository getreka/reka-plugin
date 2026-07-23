#!/bin/bash
# Shared config resolver for the reka lifecycle hooks (session-start,
# session-end, prompt-recall). Source it, then call `reka_resolve`. It sets
# three variables WITHOUT clobbering ones an earlier hook already exported:
#
#   RAG_API_URL   server URL (default http://localhost:3100)
#   RAG_API_KEY   project key, or "" for the anonymous/dev (ALLOW_ANONYMOUS) path
#   REKA_PROJECT  project namespace derived from the key (rk_<proj>_<hex>), or ""
#
# Why a durable resolver: the plugin's sensitive `rag_api_key` userConfig value
# is not persisted across restarts (Claude Code #62442), so a second-or-later
# session sees no key. We therefore fall back to the project's own gitignored
# .mcp.json (REKA_API_KEY|RAG_API_KEY) — the real source of truth per ADR-005.
#
# The namespace is ALWAYS the key's project (never a client-chosen PROJECT_NAME):
# the server overwrites X-Project-Name from the key and 403s any mismatched
# body/query projectName (enforceProjectScope), so callers carry the tenant in
# the header only and send no projectName in the body/query.
#
# Safe to source under `set -euo pipefail`: every helper returns 0.

_reka_is_template() { case "${1:-}" in *'${'*) return 0 ;; *) return 1 ;; esac; }

# Fail-loud breadcrumbs: hooks log one line per decision so silent failures
# (the 0-firings class — empty key, 401, timeout) are diagnosable after the
# fact. Capped log at $STATE/reka/hook.log. Opt out: REKA_HOOK_LOG=0.
reka_log() {
  [ "${REKA_HOOK_LOG:-1}" = "0" ] && return 0
  local d="${RAG_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/reka}"
  mkdir -p "$d" 2>/dev/null || return 0
  local f="$d/hook.log"
  if [ -f "$f" ] && [ "$(wc -c < "$f" 2>/dev/null || echo 0)" -gt 524288 ]; then
    : > "$f" 2>/dev/null || true
  fi
  printf '%s %s\n' "$(date -Is 2>/dev/null || date)" "$*" >> "$f" 2>/dev/null || true
  return 0
}

# Nearest .mcp.json: the session's project dir, then parent directories (sessions
# often start in a sub-repo of a multi-repo workspace — e.g. beep-wl/Beep-*-* —
# while the keyed .mcp.json lives at the workspace root). Stops at $HOME or /.
_reka_mcp_path() {
  local d="${CLAUDE_PROJECT_DIR:-$PWD}" i=0
  while [ -n "$d" ] && [ "$d" != "/" ] && [ "$i" -lt 6 ]; do
    if [ -r "$d/.mcp.json" ]; then printf '%s' "$d/.mcp.json"; return 0; fi
    [ "$d" = "$HOME" ] && break
    d="$(dirname "$d")"
    i=$((i + 1))
  done
  return 0
}

# First project key found in any .mcp.json server env (REKA_API_KEY|RAG_API_KEY).
_reka_mcp_key() {
  local f v=""
  f="$(_reka_mcp_path)"
  [ -n "$f" ] || { printf ''; return 0; }
  if command -v jq >/dev/null 2>&1; then
    v="$(jq -r '[.mcpServers[]?.env? | (.REKA_API_KEY // .RAG_API_KEY)] | map(select(. != null)) | .[0] // empty' "$f" 2>/dev/null || true)"
  else
    v="$(grep -oE '"(REKA|RAG)_API_KEY"[[:space:]]*:[[:space:]]*"[^"]*"' "$f" 2>/dev/null | sed -E 's/.*:[[:space:]]*"([^"]*)".*/\1/' | head -1 || true)"
  fi
  if _reka_is_template "$v"; then v=""; fi
  printf '%s' "$v"
  return 0
}

# First RAG_API_URL found in any .mcp.json server env.
_reka_mcp_url() {
  local f v=""
  f="$(_reka_mcp_path)"
  [ -n "$f" ] || { printf ''; return 0; }
  if command -v jq >/dev/null 2>&1; then
    v="$(jq -r '[.mcpServers[]?.env?.RAG_API_URL] | map(select(. != null)) | .[0] // empty' "$f" 2>/dev/null || true)"
  else
    v="$(grep -oE '"RAG_API_URL"[[:space:]]*:[[:space:]]*"[^"]*"' "$f" 2>/dev/null | sed -E 's/.*:[[:space:]]*"([^"]*)".*/\1/' | head -1 || true)"
  fi
  if _reka_is_template "$v"; then v=""; fi
  printf '%s' "$v"
  return 0
}

# rk_<proj>_<hex> -> <proj> (project names use hyphens, never underscores, so the
# trailing _<hex> is the only thing stripped).
_reka_derive_project() {
  case "${1:-}" in
    rk_*_*) local p="${1#rk_}"; printf '%s' "${p%_*}" ;;
  esac
  return 0
}

reka_resolve() {
  # KEY: inherited env (prior hook) -> userConfig -> project .mcp.json
  if [ -z "${RAG_API_KEY:-}" ]; then
    local k="${CLAUDE_PLUGIN_OPTION_RAG_API_KEY:-}"
    if _reka_is_template "$k"; then k=""; fi
    if [ -z "$k" ]; then k="$(_reka_mcp_key)"; fi
    RAG_API_KEY="$k"
  fi
  # URL: inherited env -> userConfig -> project .mcp.json -> localhost
  if [ -z "${RAG_API_URL:-}" ]; then
    local u="${CLAUDE_PLUGIN_OPTION_RAG_API_URL:-}"
    if _reka_is_template "$u"; then u=""; fi
    if [ -z "$u" ]; then u="$(_reka_mcp_url)"; fi
    if [ -z "$u" ]; then u="http://localhost:3100"; fi
    RAG_API_URL="$u"
  fi
  # PROJECT: derived from the key (the authoritative namespace). Empty => the
  # anonymous path; callers fall back to a 'default' header.
  if [ -z "${REKA_PROJECT:-}" ]; then
    REKA_PROJECT="$(_reka_derive_project "${RAG_API_KEY:-}")"
  fi
  return 0
}
