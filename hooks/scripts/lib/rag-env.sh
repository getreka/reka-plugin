#!/bin/bash
# Shared config resolver for the reka lifecycle hooks (session-start,
# session-end, prompt-recall). Source it, then call `reka_resolve`. It sets
# three variables WITHOUT clobbering ones an earlier hook already exported:
#
#   RAG_API_URL   server URL (default http://localhost:3100)
#   RAG_API_KEY   project key, or "" for the anonymous/dev (ALLOW_ANONYMOUS) path
#   REKA_PROJECT  project namespace derived from the key (rk_<proj>_<hex>), or ""
#
# Why a durable resolver: the project's own gitignored .mcp.json
# (REKA_API_KEY|RAG_API_KEY) is the source of truth per ADR-005 and is
# consulted FIRST; the plugin's user-scope `rag_api_key` (persisted by Claude
# Code in pluginSecrets and exposed as CLAUDE_PLUGIN_OPTION_RAG_API_KEY to every
# project) is only the single-project fallback.
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
# Trust gate (review 2026-08-20): with project-first precedence, a THIRD-PARTY
# repo could commit a malicious .mcp.json and route this machine's hook traffic
# (prompts, transcripts, memory files) to an attacker's server+key. A .mcp.json
# is trusted only when it is the user's own local config: NOT tracked by git
# (reka onboarding gitignores it; non-git dirs pass), or pointing at localhost.
_reka_mcp_trusted() {
  local f="$1" d; d="$(dirname "$1")"
  # Tracked in a git repo -> came with the clone -> untrusted unless localhost.
  if git -C "$d" ls-files --error-unmatch .mcp.json >/dev/null 2>&1; then
    if grep -qE '"RAG_API_URL"[[:space:]]*:[[:space:]]*"http://(localhost|127\.0\.0\.1)' "$f" 2>/dev/null; then
      return 0
    fi
    reka_log "resolver SKIP: git-tracked .mcp.json not trusted ($f)"
    return 1
  fi
  return 0
}

_reka_mcp_path() {
  local d="${CLAUDE_PROJECT_DIR:-$PWD}" i=0
  while [ -n "$d" ] && [ "$d" != "/" ] && [ "$i" -lt 6 ]; do
    if [ -r "$d/.mcp.json" ] && _reka_mcp_trusted "$d/.mcp.json"; then
      printf '%s' "$d/.mcp.json"; return 0
    fi
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

# ── Session plumbing (CC-side ids; CLAUDE_ENV_FILE never reaches other hooks) ──
# Claude Code sets CLAUDE_ENV_FILE ONLY for SessionStart/Setup/CwdChanged/
# FileChanged hooks and sources it ONLY into BashTool commands — never into
# later hook processes. So RAG_SESSION_ID cannot travel session-start ->
# prompt-recall/session-end via env. Instead every hook gets `session_id` on
# stdin (and CLAUDE_CODE_SESSION_ID in env); session-start records a map
# <cc_session_id> -> <rag_session_id> <project> <url> under the state dir and
# the later hooks read it back.
reka_state_dir() { printf '%s' "${RAG_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/reka}"; return 0; }

# reka_cc_session_id <hook-stdin-json> -> sanitized CC session id (or "").
reka_cc_session_id() {
  local s=""
  if command -v jq >/dev/null 2>&1; then
    s="$(printf '%s' "${1:-}" | jq -r '.session_id // empty' 2>/dev/null || true)"
  fi
  if [ -z "$s" ]; then
    s="$(printf '%s' "${1:-}" | grep -o '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' 2>/dev/null | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
  fi
  [ -n "$s" ] || s="${CLAUDE_CODE_SESSION_ID:-}"
  printf '%s' "$s" | tr -cd 'A-Za-z0-9._-'
  return 0
}

# reka_map_write <cc_sid> <rag_sid> <project> <url>
reka_map_write() {
  [ -n "${1:-}" ] && [ -n "${2:-}" ] || return 0
  local d; d="$(reka_state_dir)/sessions"
  mkdir -p "$d" 2>/dev/null || return 0
  printf '%s\t%s\t%s\n' "$2" "$3" "$4" > "$d/$1" 2>/dev/null || true
  return 0
}
# reka_map_read <cc_sid> -> sets REKA_MAP_SESSION / REKA_MAP_PROJECT / REKA_MAP_URL
reka_map_read() {
  REKA_MAP_SESSION=""; REKA_MAP_PROJECT=""; REKA_MAP_URL=""
  local f; f="$(reka_state_dir)/sessions/${1:-}"
  [ -n "${1:-}" ] && [ -r "$f" ] || return 0
  IFS=$'\t' read -r REKA_MAP_SESSION REKA_MAP_PROJECT REKA_MAP_URL < "$f" 2>/dev/null || true
  return 0
}
reka_map_delete() { [ -n "${1:-}" ] && rm -f "$(reka_state_dir)/sessions/$1" 2>/dev/null; return 0; }

reka_resolve() {
  # KEY+URL resolve as a PAIR, PROJECT-FIRST:
  #   inherited env -> the session's own .mcp.json (ADR-005: the key IS the
  #   namespace) -> userConfig -> localhost.
  # userConfig (CLAUDE_PLUGIN_OPTION_*) is USER-scope: Claude Code reads plugin
  # options from userSettings/flag/policy settings + pluginSecrets in the
  # credential store, never from project settings — so it is identical in every
  # project where the plugin is enabled and must never override a project that
  # carries its own key (that is how beep-wl's key leaked into cdl/beep-services).
  if [ -z "${RAG_API_KEY:-}" ]; then
    local k; k="$(_reka_mcp_key)"
    if [ -n "$k" ]; then
      RAG_API_KEY="$k"
      if [ -z "${RAG_API_URL:-}" ]; then
        local mu; mu="$(_reka_mcp_url)"
        [ -n "$mu" ] && RAG_API_URL="$mu"
      fi
    else
      k="${CLAUDE_PLUGIN_OPTION_RAG_API_KEY:-}"
      if _reka_is_template "$k"; then k=""; fi
      RAG_API_KEY="$k"
    fi
  fi
  # URL: inherited env -> (.mcp.json, paired above) -> userConfig -> localhost
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
