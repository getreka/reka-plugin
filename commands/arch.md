---
description: "Record and analyze architecture decisions using ADRs and patterns stored in RAG. MUST be used when the user discusses architecture choices, evaluates multiple approaches, or wants to record a decision. Triggers on: 'архітектура', 'ADR', 'рішення', 'який підхід', 'architecture', 'design decision', 'which approach', 'pattern', 'tech debt', 'запиши рішення'."
---

## Memory Protocol

This skill follows the RAG Memory Protocol (see `memory-protocol` skill):

- Use `context_briefing` as the entry point
- Smart remember: check for existing ADRs that the new one supersedes
- Use structured facts when recording

# RAG Architecture Decisions

## Step 0: Ensure session

If no active RAG session exists:

```
start_session(initialContext: "architecture decision: <topic>")
```

## Step 1: Understand Current State

Run **`context_briefing(task: "architecture: <topic>", files: [<relevant files>])`** for parallel context gathering. This does get_adrs, get_patterns, get_tech_debt, and hybrid_search in one call.

## Step 2: Get Architectural Guidance

Based on the decision type:

**New feature/component:**

- `hybrid_search("<feature> architecture")` + `search_graph(expandHops: 2)`

**Refactoring:**

- `search_graph(expandHops: 2)` + `get_patterns()`

**Technology choice:**

- `recall("technology decision", graphRecall: true)` + `search_docs(query)`

### Tribunal Mode (for complex decisions with 2+ options)

For rigorous multi-position analysis, use:

```
mcp__plugin_reka_rag__tribunal_debate(
  topic: "<the question>",
  positions: ["Option A", "Option B"],
  context: "<constraints>",
  useCodeContext: true,
  autoRecord: true
)
```

## Step 3: Present Analysis

```
## Architecture Analysis: {topic}

### Current State
- {existing patterns}
- {relevant ADRs}
- {tech debt in this area}

### Options
#### Option A: {name}
- Pros / Cons / Fits patterns / Conflicts with

#### Option B: {name}
- Pros / Cons / Fits patterns / Conflicts with

### Recommendation
{which option and why}
```

Wait for user's decision before recording.

## Step 4: Record Decision

**Check for superseding ADRs first:**

```
recall(query: "ADR <topic>", graphRecall: true, limit: 3)
```

**Record:**

```
record_adr(
  title: "<decision title>",
  context: "<what prompted this>",
  decision: "<what was decided>",
  consequences: "<effects>",
  alternatives: "<rejected options>",
  status: "accepted",
  tags: [<tags>]
)
```

**If new pattern emerges:** `record_pattern(...)`
**If debt introduced:** `record_tech_debt(...)`

## Step 5: Confirm

```
## Recorded
- ADR: "{title}" — accepted
- Pattern: "{name}" (if recorded)
- Tech Debt: "{title}" (if recorded)
```

## Quick Mode

For small decisions: skip Steps 1-2, go straight to Step 4.

## Language

Respond in the same language the user uses.
