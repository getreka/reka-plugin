---
description: "Onboard a new project to RAG infrastructure — configure MCP, index codebase, analyze structure. Triggers on: 'onboard', 'new project', 'setup project', 'підключи проект', 'add project', 'configure RAG', 'новий проект'."
---

## Memory Protocol

This skill follows the RAG Memory Protocol (see `memory-protocol` skill):

- Start a session for the onboarding process
- Save project profile insights to memory after indexing

# RAG Project Onboarding

Full setup: configure MCP -> index codebase -> analyze structure -> verify.

## Prerequisites

Confirm with the user:

1. **Project path** — absolute path to the project root
2. **Project name** — short identifier for collection namespacing
3. **RAG API URL** — default from plugin config

## Workflow

### Step 0: Start session

```
start_session(initialContext: "onboarding project: <projectName>")
```

### Step 1: Configure Project

Run **`setup_project`** with:

- `projectPath`: user's project path
- `projectName`: chosen name
- `updateClaudeMd`: true

This creates/updates: `.mcp.json` and `CLAUDE.md` in the project.

### Step 2: Verify Infrastructure

```bash
curl -s localhost:3100/health    # RAG API
curl -s localhost:6333/healthz   # Qdrant
curl -s localhost:8080/health    # BGE-M3 embeddings
```

If any service is down, suggest: `cd docker && docker-compose up -d`

### Step 3: Index Codebase

Run **`index_codebase`** with `path` and `force: false` (incremental).

Monitor with **`get_index_status`** — may take several minutes for large codebases.

### Step 4: Verify Index (parallel)

1. `get_index_status` — confirm collections populated
2. `get_project_stats` — collection sizes, vector counts
3. `hybrid_search("main entry point")` — verify search works

### Step 5: Smoke Test (parallel via Agent tool)

1. `find_symbol("<main export>")` — verify symbol index
2. `search_graph("<core module>")` — verify graph edges
3. `hybrid_search("<entry file> responsibilities")` + Read the entry file — verify RAG-enriched retrieval

### Step 6: Report

```
## Onboarding Complete: {projectName}

### Collections Created
| Collection | Vectors | Description |
|------------|---------|-------------|
| {name}_codebase | {count} | Source code |
| {name}_graph | {count} | Import/call edges |
| {name}_symbols | {count} | Symbol index |
| {name}_agent_memory | 0 | Durable memory |

### Next Steps
1. Restart Claude Code to load MCP config
2. Use /reka:start to begin a session
3. Try hybrid_search("...") to test search
```

### Step 7: Save project insights

```
batch_remember(items: [
  {
    content: "Project {name}: {languages}. Entry points: {main files}. Stack: {framework, DB}",
    type: "insight",
    tags: ["project-profile", "{name}"],
    metadata: { factEntities: ["{name}"], factDateTs: <timestamp> }
  }
])
```

## Re-onboarding

Use `index_codebase(path, force: true)` to re-index. Skip Step 1 unless config changes needed.

## Language

Respond in the same language the user uses.
