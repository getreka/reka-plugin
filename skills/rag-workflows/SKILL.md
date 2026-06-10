---
name: rag-workflows
description: "Search priority and tool-selection guide for RAG-powered development. Read this BEFORE your first RAG search in a session, or whenever you are unsure which tool to use among Grep/Glob, find_symbol, hybrid_search, search_graph, context_briefing, or smart_dispatch. It maps each kind of question (exact string, symbol lookup, conceptual 'how does X work', dependency/blast-radius, pre-edit briefing) to the right tool so you do not default to semantic search for everything."
---

# RAG Workflow Guide

## Search Tool Priority

Use the simplest tool that answers the question. Escalate only when needed:

| Priority | Tool                 | Use when                                         | Speed   |
| -------- | -------------------- | ------------------------------------------------ | ------- |
| 1        | **Grep/Glob**        | Exact strings, file names, known symbols         | Instant |
| 2        | **find_symbol**      | Function/class/type lookup by name               | Fast    |
| 3        | **hybrid_search**    | Semantic/conceptual ("how does X work")          | Medium  |
| 4        | **search_graph**     | Dependencies, blast radius, N-hop expansion      | Medium  |
| 5        | **context_briefing** | Before code changes (runs all above in parallel) | Medium  |
| 6        | **smart_dispatch**   | Complex multi-faceted questions (LLM-routed)     | Slow    |

## When to use which

### Direct lookup (priority 1-2)

- "Where is `FooService` defined?" → `find_symbol(name: "FooService")`
- "Find all files importing redis" → `Grep(pattern: "import.*redis")`
- "List all route files" → `Glob(pattern: "src/routes/*.ts")`

### Semantic search (priority 3)

- "How does authentication work?" → `hybrid_search(query: "authentication flow")`
- "What caching strategies are used?" → `hybrid_search(query: "caching strategy")`

### Graph traversal (priority 4)

- "What depends on embedding.ts?" → `search_graph(query: "embedding.ts", edgeTypes: ["imports"])`
- "Blast radius if I change VectorStore?" → `search_graph(query: "VectorStore", hops: 2)`

### Before code changes (priority 5)

- Always use `context_briefing(task: "...", files: [...])` before Edit/Write
- It runs recall + hybrid_search + get_patterns + get_adrs in parallel
- Returns consolidated project context in one call

### Complex questions (priority 6)

- "Analyze the performance bottleneck in the indexing pipeline" → `smart_dispatch`
- LLM analyzes the task and selects 2-5 lookups to run in parallel

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
2. **Always `context_briefing` before code changes** — the pre-edit hook warns if skipped
3. **Smart remember**: `recall` first to check for supersedes before `remember`
4. **Structured facts**: include `factEntities` and `factDateTs` in metadata
5. **Session lifecycle**: `start_session` at beginning, `/reka:end` to close
