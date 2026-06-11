---
description: "RAG-powered coding workflow that loads project context (patterns, ADRs, blast radius) before writing code. Use for non-trivial changes: multi-file edits, a new feature or dependency, or any change where existing project patterns or ADRs could alter the approach (e.g. 'implement endpoint', 'add retry logic', 'refactor the service layer', Ukrainian 'реалізуй', 'рефактор', 'додай фічу'). Do NOT invoke for mechanical single-line edits — typos, renames, version bumps, formatting — handle those directly with Edit. When unsure whether project context matters, prefer this workflow."
---

# RAG Code Workflow

Write, modify, or review code with full project context from RAG.

## When to use

For non-trivial code changes where project context matters. This includes:

- Feature implementation ("implement endpoint", "add retry logic")
- Bug fixes ("fix the timeout issue")
- Refactoring ("refactor the service layer")
- Code review ("review the diff", "check my changes")
- Changes touching multiple files, a new dependency, or shared interfaces

Skip this workflow for mechanical single-line edits (typos, renames, version
bumps, formatting) — make those directly with Edit.

## Memory Protocol

This skill follows the RAG Memory Protocol (see `memory-protocol` skill). Key points:

- **Session lifecycle**: ensure session is active (sensory buffer + working memory depend on it)
- **Smart remember**: recall before save to detect supersedes/contradicts
- **Type selection**: procedure (180d) > decision (90d) > insight (90d)
- **Structured facts**: include factEntities and factDateTs in metadata
- **graphRecall: true**: always, for spreading activation

## Phase 1: Context (gather before non-trivial changes)

If no active RAG session exists, start one first: `start_session(initialContext: '<task description>')`. If it times out, continue without it — your explicit `remember()` calls still go to durable.

### Check for prior investigation results

Before doing fresh research, check if `/reka:investigate` already analyzed this topic:

```
recall(query: "<task keywords> investigation-result", graphRecall: true)
```

Call this recall when the task may have been investigated already. If investigation results exist, they contain root cause analysis, proposed fixes, blast radius, and evidence — all ready to use. Skip to Phase 2 or Phase 3.

If no investigation results found, proceed with full context gathering below.

### Gather context

Run **`context_briefing`** with the task description and any known files:

```
context_briefing(task: "<user's request>", files: [<files if known>])
```

This single call does recall + search + patterns + ADRs + graph in parallel.

For review-only tasks, also run in parallel:

- `get_patterns` — to check compliance
- `get_tech_debt` — to flag known debt in the area

## Phase 2: Plan (skip for changes < 20 lines)

For substantial changes, present a brief plan:

```
## Plan
- **Files**: {which files change and why}
- **Approach**: {how, based on patterns from Phase 1}
- **Blast radius**: {from search_graph — what depends on changed code}
```

If the change is large or risky, wait for user confirmation. Otherwise proceed.

## Phase 3: Implement

Write code using standard tools (Read, Edit, Write, Bash). Follow:

- Patterns from `context_briefing` results
- ADRs from `context_briefing` results

### Delegate large work

For a multi-file change or more than ~100 new lines, delegate the
implementation to the **feature-builder** agent (via the Task tool). Delegate
the accompanying test work either to a general-purpose Task subagent or as part
of the same feature-builder delegation, then synthesize the results. For
small, focused changes, implement directly here.

## Phase 4: Verify

After implementation:

1. Build check: run the project's build command (e.g., `npm run build` or `tsc --noEmit`)
2. If the change touches exports or shared interfaces: `search_graph(expandHops: 1)` to check downstream consumers

For review-only tasks: read the code, compare against patterns and ADRs, present findings with severity levels (Critical/Warning/Info).

## Phase 5: Remember

After a session with meaningful code edits, save what the consolidation agent
can't infer automatically (key decisions, non-obvious gotchas). Skip this for
trivial edits that produced no durable knowledge.

### Check for existing memories first (smart remember)

```
recall(query: "<topic of what you're about to save>", graphRecall: true, limit: 3)
```

If a similar memory exists, note "Supersedes: <old_id>" in content.

### Save with structured facts

```
remember(
  content: "<key decisions, non-obvious gotchas, important context>",
  type: "procedure",  // or "decision", "insight"
  tags: [<relevant tags>],
  metadata: {
    factEntities: ["<changed-file.ts>", "<ServiceName>"],
    factDateTs: <unix-timestamp-seconds>
  }
)
```

**Memory type guide** (controls longevity via Ebbinghaus decay):

- `procedure` (180 days) — step-by-step workflows, how-to knowledge
- `decision` (90 days) — choices made and why
- `insight` (90 days) — discoveries, non-obvious facts

If an architectural decision was made: `record_adr(title, context, decision, consequences)`
If tech debt was introduced: `record_tech_debt(title, description, location, impact, suggestedFix)`

## DB Changes (special flow)

Before any database/schema changes:

1. `recall(query: "<table name> schema", graphRecall: true)` — prior schema
   knowledge. Convention: DB facts are saved with tags `db-schema` and
   `db-rule`, so include the table name and those tags in the query.
2. Read the actual migration files / schema definitions for current structure.
3. Validate the proposed change against any recalled rules and constraints.

After migration: `remember` the new structure and any constraints with
`tags: ["db-schema", "<table>"]` (rules get `tags: ["db-rule", "<table>"]`)
so future sessions can recall them.

## Language

Respond in the same language the user uses.
