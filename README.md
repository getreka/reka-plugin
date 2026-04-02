# Reka Plugin for Claude Code

RAG-powered AI development: semantic search, project memory, architecture decisions, and coding workflows.

## What it does

Reka connects Claude Code to your project's RAG infrastructure, giving the AI assistant:

- **Semantic search** across your codebase (code, docs, Confluence)
- **Project memory** — decisions, patterns, insights that persist across sessions
- **Architecture awareness** — ADRs, dependency graphs, blast radius analysis
- **Structured workflows** — coding, investigation, review, and onboarding

## Installation

### Step 1: Add marketplace

```
/plugin marketplace add getreka/reka-plugin
```

### Step 2: Install plugin

```
/plugin install reka@reka-plugins
```

### Auto-install for team (project settings)

Add to `.claude/settings.json` to auto-discover for everyone:

```json
{
  "extraKnownMarketplaces": {
    "reka-plugins": {
      "source": {
        "source": "github",
        "repo": "getreka/reka-plugin"
      }
    }
  },
  "enabledPlugins": {
    "reka@reka-plugins": true
  }
}
```

### Local development

```bash
claude --plugin-dir ./reka-plugin
```

### Configuration

On first enable, Claude Code prompts for:

| Setting        | Description                                    | Example                 |
| -------------- | ---------------------------------------------- | ----------------------- |
| `rag_api_url`  | RAG API server URL                             | `http://localhost:3100` |
| `rag_api_key`  | API authentication key (stored in OS keychain) | `e699194c-...`          |
| `project_name` | Collection namespace identifier                | `myapp`                 |

## Commands

| Command               | Description                                                              |
| --------------------- | ------------------------------------------------------------------------ |
| `/reka:start`         | Start a RAG session, show project stats                                  |
| `/reka:end`           | Save knowledge, close session, trigger consolidation                     |
| `/reka:code`          | 5-phase RAG coding: context → plan → implement → verify → remember       |
| `/reka:investigate`   | Deep research: find, trace, debug — saves to memory, never modifies code |
| `/reka:review`        | Architecture-aware code review against patterns and ADRs                 |
| `/reka:arch`          | Record and analyze architecture decisions (ADRs)                         |
| `/reka:debate`        | Adversarial tribunal debate for complex decisions                        |
| `/reka:onboard`       | Set up RAG for a new project                                             |
| `/reka:memory-review` | Triage quarantine, promote/reject auto-memories                          |
| `/reka:restart-api`   | Rebuild and restart local rag-api server                                 |

## Agents

| Agent                  | Model  | Purpose                                               |
| ---------------------- | ------ | ----------------------------------------------------- |
| `reka:rag-ops`         | Haiku  | Operations: indexing, collections, memory maintenance |
| `reka:feature-builder` | Sonnet | Feature implementation with RAG context               |
| `reka:code-reviewer`   | Sonnet | Code review against patterns and ADRs                 |
| `reka:test-writer`     | Sonnet | Test generation (auto-detects framework)              |
| `reka:rag-researcher`  | Haiku  | Codebase research via semantic search                 |

All agents have `memory: project` — they learn and improve across sessions.

## Hooks

| Event                    | Action                                          |
| ------------------------ | ----------------------------------------------- |
| SessionStart             | Auto-starts RAG session, injects env vars       |
| PreToolUse (Edit/Write)  | Warns if no RAG session active                  |
| PostToolUse (Edit/Write) | Auto-formats with prettier, runs tsc type-check |
| Stop                     | Ends RAG session, triggers consolidation agent  |

## Skills (reference)

- **memory-protocol** — Shared protocol for session lifecycle, smart remember, memory types
- **rag-workflows** — Search tool priority and selection guide
- **obsidian-sync** — Bidirectional sync between RAG memories and Obsidian vault

## Prerequisites

- RAG API server running (local or remote)
- Qdrant vector database
- Embedding service (BGE-M3 or OpenAI)

Recommended: also install `typescript-lsp@claude-plugins-official` for TypeScript code intelligence.

## Architecture

```
Claude Code + Reka Plugin
  │
  ├── Commands (/reka:code, /reka:investigate, ...)
  ├── Agents (feature-builder, code-reviewer, ...)
  ├── Hooks (session lifecycle, quality checks)
  │
  └── MCP Server (@getreka/mcp)
        │
        ├── 35 core tools (search, memory, architecture, ...)
        │
        └── RAG API (:3100)
              ├── Qdrant (vectors)
              ├── Ollama / Claude (LLM)
              └── BGE-M3 (embeddings)
```

## License

BSL-1.1
