# Changelog

All notable changes to the reka plugin are documented here. This project adheres
to [Semantic Versioning](https://semver.org/).

## 0.6.1 — 2026-07-23

### Fixed (auto-recall reliability — ADR-006 phase 0)

- **`rag-env.sh` resolves `.mcp.json` by walking parent directories** (up to 6
  levels, stopping at `$HOME`): sessions started in a sub-repo of a multi-repo
  workspace (e.g. `beep-wl/Beep-SaaS-AppEngine`) previously resolved an empty
  key and silently 401'd against the keyed server.
- **`prompt-recall.sh` guards the empty-key + remote-server case** instead of
  curling into a guaranteed silent 401 (anonymous stays allowed on localhost).
- **Recall timeout raised `-m 3` → `-m 8`** — graph recall over remote HTTPS
  routinely exceeded 3s; stays inside the hook's 10s budget.
- **Fail-loud breadcrumbs**: `reka_log` writes one line per hook decision to
  `$XDG_STATE_HOME/reka/hook.log` (capped, opt out `REKA_HOOK_LOG=0`). The
  0-firings class of failures survived two prior releases because every path
  exited silently.
- Documented operational cause found during rollout: the hook hard-requires
  `jq`; on a machine without it, auto-recall can never fire. Verified live
  firing end-to-end after the fixes (first observed injection of this hook).

## 0.6.0 — 2026-06-26

### Removed (Subtraction sweep)

- **`/reka:debate`** and the **`tribunal_debate`** capability — 0 invocations
  across 37+ audited sessions. Deleted in full across the stack (plugin command,
  `arch.md` Tribunal Mode, the `@getreka/mcp` tool, and the rag-api/dashboard
  tribunal stack). Requires `@getreka/mcp` ≥ 0.7.0.
- **`/reka:memory-review`** — 0 invocations; quarantine triage lives in
  `/reka:end` plus the `review_memories`/`promote_memory` tools, and governance
  maintenance runs server-side.
- **`/reka:start`** — a status display superseded by the SessionStart hook.
- **`rag-ops`** agent — orphaned from the command spine (its tools remain on the
  MCP surface).
- **`obsidian-sync`** skill — broad triggers, depended on an `mcp__obsidian__*`
  server most projects lack.

### Changed

- Docs truth pass (Proof rule): dropped the Confluence-search claim and the
  phantom `/reka:obsidian-sync` reference; corrected the skill description
  (`rag-workflows` auto-invokes, `memory-protocol` is read by path); updated the
  architecture diagram to 6 commands / 3 agents / 2 skills / **28 tools**.

## 0.5.0 — 2026-06-26

### Fixed

- **Session lifecycle no longer fails closed on key-scoped projects.** The
  SessionStart/SessionEnd hooks sent `projectName:"default"` in the start body,
  digest query, and end body, which the RAG API's project-scope guard rejected
  with `403 PROJECT_SCOPE_VIOLATION` on any keyed project — silently killing the
  session digest and the end/consolidation call. The hooks now send no client
  `projectName`; the tenant is carried by the `X-Project-Name` header, which the
  server derives from the API key (ADR-005).
- Hooks resolve the API key durably from the project's `.mcp.json`
  (`REKA_API_KEY`/`RAG_API_KEY`) when the non-persisted plugin `userConfig` key
  is unavailable after a restart, and derive the namespace from the key
  (`rk_<project>_…`).

### Added

- **Zero-action auto-recall.** A new `UserPromptSubmit` hook recalls relevant
  project memory on substantive coding prompts and injects it into context
  before the model acts — no command required. Opt out with `REKA_AUTO_RECALL=0`;
  throttle via `REKA_RECALL_THROTTLE_SEC`.

### Changed

- `.mcp.json` / `plugin.json`: dropped `PROJECT_NAME` / the `project_name`
  userConfig (the namespace derives from the key, ADR-005); renamed the bundled
  server's `RAG_API_KEY` env var to `REKA_API_KEY`.
- SessionStart hook timeout 10→20s, SessionEnd 20→25s (so transcript capture +
  the end call fit the budget); hook state moved to `$XDG_STATE_HOME/reka` so the
  idempotency marker survives `/tmp` wipes.

### Security

- Hook env values are written to `CLAUDE_ENV_FILE` with `printf %q`, so a key
  carrying shell metacharacters cannot execute when Claude Code sources the file.
