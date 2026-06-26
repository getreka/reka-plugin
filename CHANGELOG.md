# Changelog

All notable changes to the reka plugin are documented here. This project adheres
to [Semantic Versioning](https://semver.org/).

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
