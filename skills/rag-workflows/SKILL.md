---
name: rag-workflows
description: "Search priority and tool-selection guide for RAG-powered development. Read this BEFORE your first RAG search in a session, or whenever you are unsure which tool to use among Grep/Glob, find_symbol, hybrid_search, search_graph, or context_briefing. It maps each kind of question (exact string, symbol lookup, conceptual 'how does X work', dependency/blast-radius, pre-edit briefing) to the right tool so you do not default to semantic search for everything."
---

# RAG Workflow Guide

## Search Tool Priority

Use the simplest tool that answers the question. Escalate only when needed:

| Priority | Tool                 | Use when                                                                                                                                                    | Speed   |
| -------- | -------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- | ------- |
| 1        | **Grep/Glob**        | Exact strings, file names, known symbols                                                                                                                    | Instant |
| 2        | **find_symbol**      | You know a function/class/type NAME and want its exact definition and location                                                                              | Fast    |
| 3        | **hybrid_search**    | You need to find code and don't know the exact file or symbol name — conceptual questions ("how does X work")                                               | Medium  |
| 4        | **search_graph**     | Dependency structure: what imports a file, what a change would break (blast radius), how modules connect                                                    | Medium  |
| 5        | **context_briefing** | Before changes that span multiple files, touch shared services/exports, or where prior patterns/ADRs could affect the approach (runs all above in parallel) | Medium  |

## When to use which

### Direct lookup (priority 1-2)

- "Where is `FooService` defined?" → `find_symbol(name: "FooService")`
- "Find all files importing redis" → `Grep(pattern: "import.*redis")`
- "List all route files" → `Glob(pattern: "src/routes/*.ts")`
- Do NOT use `find_symbol` for conceptual questions ("how does X work") — use `hybrid_search`

### Semantic search (priority 3)

- "How does authentication work?" → `hybrid_search(query: "authentication flow")`
- "What caching strategies are used?" → `hybrid_search(query: "caching strategy")`
- Do NOT use for exact strings or known file names (use Grep/Glob) or when you already know a symbol name (use `find_symbol`)

### Graph traversal (priority 4)

- "What depends on embedding.ts?" → `search_graph(query: "embedding.ts", edgeTypes: ["imports"])`
- "Blast radius if I change VectorStore?" → `search_graph(query: "VectorStore", hops: 2)`
- Do NOT use for finding code by topic or concept (use `hybrid_search`) or plain symbol lookup (use `find_symbol`)

### Before code changes and complex questions (priority 5)

- Call `context_briefing(task: "...", files: [...])` before changes that span multiple files, touch shared services/exports, or where prior decisions (patterns/ADRs) could affect the approach
- Do NOT use for mechanical single-line edits (typos, renames, version bumps, formatting) — make those directly
- It runs recall + hybrid_search + get_patterns + get_adrs in parallel
- Returns consolidated project context in one call
- Also the right tool for complex multi-faceted questions ("analyze the performance bottleneck in the indexing pipeline") — follow up with targeted `search_graph` / `find_symbol` calls as needed

## Memory Tools

| Tool       | Use when                                                                                                                                                                           |
| ---------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `recall`   | Past decisions, insights, ADRs, or notes could change your approach. NOT for searching code (hybrid_search/Grep) or docs (search_docs)                                             |
| `remember` | Once per work item, only when you learned something non-obvious — a decision, a gotcha, or a new procedure — and include the WHY. NOT for mechanical changes (they pollute recall) |
| `memory`   | Path-based notes the model maintains itself (view/create/str_replace under `/memories`); writes are quarantined until promoted                                                     |

## Memory Type Quick Reference

| Type        | Stability | Use for                         |
| ----------- | --------- | ------------------------------- |
| `procedure` | 180 days  | How-to, workflows, deploy steps |
| `decision`  | 90 days   | Why X was chosen over Y         |
| `insight`   | 90 days   | Non-obvious facts, discoveries  |
| `note`      | 90 days   | General observations            |
| `context`   | 90 days   | Session background              |

## Graph Edge Types

| Edge          | Meaning                 | Example                                         |
| ------------- | ----------------------- | ----------------------------------------------- |
| `imports`     | File imports another    | `routes/search.ts` → `services/vector-store.ts` |
| `extends`     | Class extends another   | `CacheService` → `BaseService`                  |
| `implements`  | Implements interface    | `OllamaProvider` → `LLMProvider`                |
| `calls`       | Function calls another  | `handleSearch` → `vectorStore.search`           |
| `supersedes`  | Memory replaces another | New ADR replaces old ADR                        |
| `contradicts` | Memory conflicts        | Two conflicting decisions                       |
| `caused_by`   | Causal relationship     | Bug caused by config change                     |

## Key Rules

1. **Always `graphRecall: true`** when using `recall` — enables spreading activation
2. **`context_briefing` before non-trivial changes** — multi-file edits, shared services/exports, or where patterns/ADRs matter; skip it for mechanical single-line edits
3. **Smart remember**: `recall` first to check for supersedes before `remember`
4. **Remember discipline**: once per work item, only non-obvious learnings, include the why
5. **Structured facts**: include `factEntities` and `factDateTs` in metadata
6. **Session lifecycle**: `start_session` at beginning, `/reka:end` to close
