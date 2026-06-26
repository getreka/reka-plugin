---
description: "Save knowledge and wrap up a working session. Use when the user finishes work, says goodbye, or indicates they're done — triggers on: 'done', 'все', 'дякую', 'закінчили', 'готово', 'wrap up', 'save session', 'end session'. Also use PROACTIVELY when you notice the user has completed significant work and hasn't saved context yet."
---

# RAG Session End

Save knowledge from the current session so future sessions have full context.

## Memory Protocol

This skill follows the RAG Memory Protocol (see `memory-protocol` skill). As the session-closing skill, it has special responsibilities:

- Trigger consolidation via `end_session` (distills session knowledge into long-term memory)
- Review quarantine queue before closing
- Use structured facts in remember calls
- Smart remember: recall before save to detect supersedes

## How memory works

- **Sensory buffer** captures every tool call automatically
- **Working memory** holds the most salient events from this session
- **Consolidation agent** runs at `end_session` — processes working memory into LTM
- **Your explicit `remember` calls** go directly to durable storage

Your job: save **key decisions, non-obvious insights, and procedures** that a machine might miss.

## When to trigger

- User explicitly says they're done
- User just committed code and seems to be wrapping up
- Significant work was done but no `remember` was called yet

## Workflow

### Step 0: Check for active session

Check if there's an active RAG session. If yes, note its `sessionId` for Step 4.

**If no active session**: Skip `end_session` and `review_memories`. Still do Steps 1-2. Tell the user: "Session wasn't active — saved memories directly to durable."

### Step 1: Save key knowledge

Focus on what the consolidation agent can't infer alone:

```
remember(
  content: "<what was done, key decisions, files changed, gotchas>",
  type: "insight",  // or "decision", "procedure"
  tags: [<relevant tags>],
  metadata: {
    factEntities: ["entity1", "entity2"],
    factDateTs: <unix-timestamp>
  }
)
```

For multiple findings, use `batch_remember`.

### Step 2: Record decisions (if applicable)

- `record_adr(title, context, decision, consequences)` — architectural decisions
- `record_pattern(name, description, structure, example)` — new patterns
- `record_tech_debt(title, description, location, impact, suggestedFix)` — tech debt

### Step 3: Review quarantine (quick triage)

```
review_memories
```

If quarantine has items:

- Promote clearly valuable ones: `promote_memory(memoryId, reason: "human_validated")`
- Skip uncertain ones — they live 7 days; governance maintenance expires them

### Step 4: Close session

```
## Saved
- Memory: {what was remembered}
- ADR: {title} (if recorded)
- Quarantine: {N promoted, M skipped} (if reviewed)
```

Then close:

```
end_session(summary: "<brief summary of what was accomplished>")
```

This triggers the consolidation agent server-side.

## Language

Respond in the same language the user uses.
