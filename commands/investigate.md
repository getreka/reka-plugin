---
description: "Deep, multi-file codebase investigation using RAG — trace dependencies across modules, understand how a subsystem works end-to-end, and find the root cause behind a pasted stack trace or error. Use for cross-module 'how does X work', root-cause analysis of an error/log/stack trace, or research that spans several files (e.g. 'дослідж', 'why does X happen', 'trace the call chain', 'root cause of this exception'). Do NOT invoke for a single-symbol lookup answerable with one Grep or find_symbol ('where is function foo', 'find the User type') — answer those directly. If the user asks to investigate AND fix, do the investigation then proceed to the fix; do not dead-end at a handoff."
---

# RAG Investigation

Find implementations, trace dependencies, understand code, debug errors, and propose solutions — all saved to memory for later implementation.

## Core principle

**Investigate first.** This skill produces analysis, root causes, and proposed
solutions, and saves everything to RAG memory so the work isn't lost. When the
user asked only to understand or diagnose, stop after the handoff and let them
decide when to implement. When the user asked to investigate **and** fix in the
same request, complete the investigation, then proceed to the fix (following the
`/reka:code` flow) rather than dead-ending at a handoff.

## Memory Protocol

This skill follows the RAG Memory Protocol (see `memory-protocol` skill). Key points:

- Ensure session is active (`start_session` if needed)
- Smart remember: recall before save to detect supersedes/contradicts
- Use structured facts (factEntities, factDateTs) when saving
- Always `graphRecall: true` for spreading activation

## Step 0: Ensure session

If no active RAG session exists:

```
start_session(initialContext: "investigation: <topic>")
```

## Step 1: Classify

| Type                                     | User signals                | Primary tools                                     |
| ---------------------------------------- | --------------------------- | ------------------------------------------------- |
| **Find** (where is X?)                   | "where is", "find"          | `find_symbol` + `hybrid_search`                   |
| **Understand** (how does X work?)        | "explain", "how does"       | `hybrid_search` + `search_graph` + `get_patterns` |
| **Dependencies** (what uses X?)          | "blast radius", "what uses" | `search_graph(expandHops: 2)` + `hybrid_search`   |
| **Call trace** (who calls X?)            | "call chain", "callers"     | `search_graph` with `calls` edges                 |
| **Rationale** (why was X done this way?) | "why", "decision"           | `get_adrs` + `recall(graphRecall: true)`          |
| **Debug** (X is broken)                  | error message, stack trace  | `context_briefing` + `recall` + `hybrid_search`   |
| **Diagnose** (find root cause)           | "root cause", "diagnose"    | all of the above + `search_graph` blast radius    |

## Step 2: Check previous investigations

```
recall(query: "<topic keywords> investigation-result", graphRecall: true)
```

If found, present to user: "A previous investigation on this topic exists. Build on it or start fresh?"

## Step 3: Broad search

When the investigation spans multiple modules or needs several independent
searches, delegate to the **rag-researcher** agent (via the Task tool) — launch
2-3 in parallel, then synthesize their findings. For a narrow question you can
answer with one or two searches, run the tools directly without delegating.

```
Agent 1 (rag-researcher): hybrid_search("<query>") + find_symbol("<symbol>")
Agent 2 (rag-researcher): search_graph("<file>", expandHops: 2)
Agent 3 (rag-researcher): recall("<query>", graphRecall: true) + get_adrs("<topic>")
```

For **Debug/Diagnose** specifically, also run:

- `context_briefing(task: "debug: <error>", files: [<from stack trace>])` — full context in one call
- Call graph trace via `search_graph` on the broken function

## Step 4: Deep dive

Based on search results:

1. **Read key files** (2-3 most relevant)
2. **Trace further** with `search_graph(expandHops: 2)` if dependency chain is unclear
3. For debugging: `git log --oneline -10 -- <file>` on recently changed files
4. **Blast radius**: always run `search_graph` on the affected area

## Step 5: Synthesize findings

Structure based on investigation type (Find/Understand/Dependencies/Debug). Include:

- Root cause (for debug)
- Evidence with file:line refs
- Trace / call chain
- Blast radius
- Proposed fix
- Risks and side effects

## Step 6: Save to memory (NEVER skip)

### Smart remember: check for existing investigations first

```
recall(query: "<topic keywords>", graphRecall: true, limit: 3)
```

### Save with structured facts:

```
remember(
  content: "INVESTIGATION: {topic}\n\nRoot cause: {root cause}\nAffected files: {file list}\nProposed fix: {approach}\nEvidence: {key findings}",
  type: "procedure",  // or "insight" for find/understand results
  tags: ["investigation-result", "<component>"],
  metadata: {
    factEntities: ["<affected-file.ts>", "<ServiceName>"],
    factDateTs: <unix-timestamp-seconds>
  }
)
```

The tag `investigation-result` bridges this skill and `/reka:code`.

## Step 7: Handoff

```
## Next steps

Investigation saved to RAG memory. To implement the fix:
-> /reka:code {brief task description}

The coding workflow will automatically load these investigation results.
```

If the user asked only to understand or diagnose, stop here — let them decide
when to implement. If the user explicitly asked to investigate **and** fix,
skip the handoff and proceed to implement the fix using the `/reka:code` flow.

## Language

Respond in the same language the user uses.
