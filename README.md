<p align="center">
  <img src="https://img.shields.io/badge/Claude_Code-Plugin-7C3AED?style=for-the-badge&logo=data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0id2hpdGUiPjxwYXRoIGQ9Ik0xMiAyQzYuNDggMiAyIDYuNDggMiAxMnM0LjQ4IDEwIDEwIDEwIDEwLTQuNDggMTAtMTBTMTcuNTIgMiAxMiAyem0wIDE4Yy00LjQyIDAtOC0zLjU4LTgtOHMzLjU4LTggOC04IDggMy41OCA4IDgtMy41OCA4LTggNHoiLz48L3N2Zz4=" alt="Claude Code Plugin"/>
  <img src="https://img.shields.io/badge/version-0.7.0-blue?style=for-the-badge" alt="Version"/>
  <img src="https://img.shields.io/badge/license-BSL--1.1-green?style=for-the-badge" alt="License"/>
</p>

<h1 align="center">Reka — Claude Code Plugin</h1>

<p align="center">
  <strong>RAG-powered AI development for any codebase</strong><br/>
  Semantic search · Project memory · Architecture decisions · Coding workflows
</p>

---

## Overview

Reka is a [Claude Code plugin](https://code.claude.com/docs/en/plugins) that connects your AI assistant to a shared RAG (Retrieval-Augmented Generation) infrastructure. It gives Claude persistent project memory, semantic codebase search, architecture awareness, and structured development workflows — across sessions and team members.

### What you get

| Capability                 | How it works                                                                                |
| -------------------------- | ------------------------------------------------------------------------------------------- |
| **Semantic search**        | Search code and docs by meaning, not just keywords                                          |
| **Project memory**         | Decisions, patterns, and insights persist across sessions via Ebbinghaus-inspired retention |
| **Architecture awareness** | ADRs, dependency graphs, blast radius analysis before every change                          |
| **Structured workflows**   | 5-phase coding, deep investigation, architecture review, and more                           |
| **Auto session lifecycle** | Hooks start/end RAG sessions automatically, trigger memory consolidation                    |

---

## Quick Start

### 1. Add marketplace

```
/plugin marketplace add getreka/reka-plugin
```

### 2. Install plugin

```
/plugin install reka@reka-plugins
```

### 3. Configure

On first enable, Claude Code prompts for three settings:

| Setting          | Description                                | Example                 |
| ---------------- | ------------------------------------------ | ----------------------- |
| **RAG API URL**  | Your RAG API server                        | `http://localhost:3100` |
| **RAG API Key**  | Project-scoped key (`rk_{project}_…`)       | `rk_myapp_…`            |
| **Project Name** | Used to mint the key; the namespace is resolved from the key | `myapp`   |

> **Multiple projects on one machine?** The single bundled config above is for one
> project. For several repos, run `npx @getreka/cli init` (or `/reka:onboard`) **once
> per project** — each writes its own gitignored `.mcp.json` with its own
> `rk_{project}_…` key and resolves its own namespace from that key, independently.

### Team auto-install

Add to your project's `.claude/settings.json` so everyone gets it automatically:

```json
{
  "extraKnownMarketplaces": {
    "reka-plugins": {
      "source": { "source": "github", "repo": "getreka/reka-plugin" }
    }
  },
  "enabledPlugins": {
    "reka@reka-plugins": true
  }
}
```

---

## Commands

### Coding & Review

| Command             | Description                                                              |
| ------------------- | ------------------------------------------------------------------------ |
| `/reka:code`        | 5-phase workflow: context → plan → implement → verify → remember         |
| `/reka:investigate` | Deep research — find, trace, debug. Saves to memory, never modifies code |
| `/reka:review`      | Architecture-aware code review against patterns and ADRs                 |

### Architecture

| Command        | Description                                                       |
| -------------- | ----------------------------------------------------------------- |
| `/reka:arch`   | Record and analyze architecture decisions (ADRs)                  |

### Session & Memory

| Command               | Description                                                             |
| --------------------- | ----------------------------------------------------------------------- |
| `/reka:end`           | Save knowledge, close session, trigger memory consolidation             |

### Setup

| Command         | Description                                            |
| --------------- | ------------------------------------------------------ |
| `/reka:onboard` | Set up RAG for a new project: configure, index, verify |

---

## Agents

Internal subagents used by the workflows — `/reka:code`, `/reka:investigate`, and `/reka:review` delegate to them via the Task tool. For direct requests, prefer the corresponding `/reka:*` command.

| Agent                  | Model  | Used by                                                            |
| ---------------------- | ------ | ------------------------------------------------------------------ |
| `reka:feature-builder` | Sonnet | `/reka:code` Phase 3 — multi-file implementations with RAG context |
| `reka:code-reviewer`   | Sonnet | `/reka:review` — per-file review against patterns and ADRs         |
| `reka:rag-researcher`  | Haiku  | `/reka:investigate` — parallel semantic search and graph traversal |

All agents have **persistent memory** (`memory: project`) — they learn your codebase patterns across sessions.

---

## Hooks

| Event            | Action                                                                                             |
| ---------------- | -------------------------------------------------------------------------------------------------- |
| **SessionStart** | Auto-starts RAG session, injects `RAG_SESSION_ID` env var, injects the session digest into context |
| **SessionEnd**   | Ships the session transcript to your RAG API, ends the RAG session, triggers consolidation agent   |

Transcript capture sends the last 2 MiB of the Claude Code transcript to `POST /api/capture/transcript` on the RAG API URL you configured — your own server is the only destination; the plugin sends data nowhere else. Set `REKA_TRANSCRIPT_CAPTURE=0` to disable it.

---

## Skills

Skills — `rag-workflows` auto-invokes on development tasks; `memory-protocol` is a write-side reference the `/reka:*` commands read by path:

- **rag-workflows** — Search tool priority guide (Grep → find_symbol → hybrid_search → search_graph → context_briefing)
- **memory-protocol** — Session lifecycle, smart remember with relationship detection, memory type selection, structured facts

---

## Architecture

```
Claude Code
  │
  └── Reka Plugin
        ├── 6 Commands (/reka:code, /reka:investigate, ...)
        ├── 3 Agents (feature-builder, rag-researcher, code-reviewer)
        ├── 2 Skills (memory-protocol, rag-workflows)
        ├── 3 Hooks (session lifecycle + prompt auto-recall)
        │
        └── MCP Server (@getreka/mcp)
              │  28 tools: search, memory, architecture, sessions, agents
              │
              └── RAG API
                    ├── Qdrant — vector database
                    ├── Ollama — embeddings (qwen3-embedding) + local LLM
                    └── Claude — complex tasks (optional, hybrid routing)
```

---

## Prerequisites

- **RAG API** server running ([getreka/reka](https://github.com/getreka/reka))
- **Qdrant** vector database
- **Ollama** — embeddings + local LLM (default provider)

Optional but recommended:

- `typescript-lsp@claude-plugins-official` for TypeScript code intelligence

---

## Local Development

```bash
claude --plugin-dir ./reka-plugin
```

Use `/reload-plugins` after making changes to pick up updates without restarting.

Test the hooks (plain bash, mocks curl via a PATH shim):

```bash
bash tests/session-start.test.sh
bash tests/session-end.test.sh
```

---

## License

[BSL-1.1](LICENSE)
