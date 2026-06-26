---
name: memory-protocol
description: "Shared RAG Memory Protocol reference doc — NOT model-invocable and NOT auto-triggered. When a command or skill says 'follow the Memory Protocol' or 'see the memory-protocol skill', READ this file directly by path (skills/memory-protocol/SKILL.md) and apply it. Defines session lifecycle, smart remember with relationship detection, memory type selection, structured facts, graph-aware recall, and quarantine awareness."
disable-model-invocation: true
---

# RAG Memory Protocol

This is a shared **reference document**, not an invocable skill. It has `disable-model-invocation: true`, so it is never auto-triggered and cannot be launched as a skill — a command referencing "the memory-protocol skill" will not resolve to a runnable action. Instead, when another command or skill says "follow the Memory Protocol" (or references this file), READ it directly by its path — `skills/memory-protocol/SKILL.md` — and apply the rules below inline.

## Why this protocol exists

The project has a human-memory-inspired architecture with 4 phases: sensory buffer, working memory, consolidation agent, and long-term memory. Without this protocol, skills use only ~30% of these capabilities — sessions aren't started, memories aren't typed properly, quarantine fills up and gets deleted, structured facts aren't populated, and memory relationships degrade into flat duplicates.

Following this protocol means the full architecture works as designed.

---

## 0. Which memory system (avoid double-writing)

There are two distinct memory systems — this protocol governs only the first:

- **Team-shared RAG memory** (`remember` / `recall` / `record_adr` / etc.): the project-scoped, vector-indexed long-term store described in this document. Use it for findings, decisions, patterns, and facts that the team — and future sessions across machines — should retrieve. This is the system this protocol covers.
- **Native Claude Code auto-memory** (the local `MEMORY.md` the harness maintains): personal, machine-local notes the harness writes and reads automatically. It is not project-shared and is not searchable via `recall`.

Do NOT write the same content to both. When the protocol says `remember` / `recall`, it always means the RAG tools above. Let the native auto-memory be managed by the harness on its own; don't mirror RAG memories into it or vice versa, or the two will drift and duplicate.

---

## 1. Session Lifecycle

Every skill that does substantive work (not just a quick lookup) should ensure a session exists.

### Start session (if not already active)

At the beginning of any multi-step workflow:

```
start_session(initialContext: "<what you're about to do>")
```

This initializes the sensory buffer (captures every tool call) and working memory (promotes high-salience events). Without a session, these systems are dormant.

If the user already started a session earlier in the conversation, skip this — don't start a second one.

### End session (only /reka:end does this)

Individual skills do NOT call `end_session`. That's `/reka:end`'s job. But every skill should save its key findings via `remember` before the conversation ends, because if end_session never gets called, those explicit memories are the only thing that survives.

---

## 2. Smart Remember (relationship-aware)

Before saving a new memory, check if a related memory already exists. This prevents duplicates and creates typed relationship edges instead of flat `relates_to` noise.

### Pattern:

```
# 1. Check for existing memories on this topic
recall(query: "<topic keywords>", graphRecall: true, limit: 3)

# 2. If similar memory found:
#    - If your new finding REPLACES it → note in content: "Supersedes: <old_id>"
#    - If it CONTRADICTS → note: "Contradicts: <old_id>: <what changed>"
#    - If it EXTENDS → note: "Extends: <old_id>"

# 3. Save with relationship context
remember(
  content: "<your finding>\n\n[Supersedes: <old_memory_id> — <reason>]",
  type: "<see Type Selection below>",
  tags: [<relevant tags>]
)
```

The relationship classifier will pick up the "Supersedes/Contradicts/Extends" hint and create proper typed edges.

### Verification step (for supersedes only):

After saving the new memory, call `forget` on the old one if the supersedes is clear-cut:

```
# After remember() succeeds with "Supersedes: <old_id>":
forget(memoryId: "<old_id>")
```

**When NOT to forget**: If the old memory has additional context not captured in the new one, keep both — the classifier will link them with a `supersedes` edge, and recall will prefer the newer one.

### When to skip the check:

- First memory on a topic (nothing to supersede)
- Time-sensitive saves where the extra recall would slow the workflow noticeably
- Batch operations (`batch_remember`) — check once at the batch level, not per item

---

## 3. Memory Type Selection

Types control how long a memory lives via Ebbinghaus decay. Choose consciously:

| Type        | Base Stability | Use for                                  | Examples                                |
| ----------- | -------------- | ---------------------------------------- | --------------------------------------- |
| `procedure` | **180 days**   | Step-by-step workflows, how-to knowledge | "To deploy X: first Y, then Z"          |
| `decision`  | **90 days**    | Choices made and why                     | "Chose Redis over Memcached because..." |
| `insight`   | **90 days**    | Discoveries, non-obvious facts           | "The batch endpoint has a 32MB limit"   |
| `note`      | **90 days**    | General observations                     | "Team prefers PascalCase for services"  |
| `context`   | **90 days**    | Background for future sessions           | "Working on Sprint 12, focus on auth"   |

### Rules of thumb:

- **If it's steps someone would follow again** → `procedure` (longest-lived)
- **If it explains WHY something was done** → `decision`
- **If it's a non-obvious fact about the code** → `insight`
- **If it's an investigation result with a proposed fix** → `procedure` (it contains steps to follow)
- **Default** → `insight` (safe middle ground)

---

## 4. Structured Facts

When saving memories, include structured fields so the TEMPR retrieval pipeline (temporal + entity search) can find them:

```
remember(
  content: "...",
  type: "insight",
  tags: ["component-name", "topic"],
  metadata: {
    factEntities: ["embedding.ts", "EmbeddingService", "Ollama"],
    factDateTs: 1743350400  // Unix timestamp (seconds) — today's date
  }
)
```

### factEntities — what to include:

- File names mentioned in the finding
- Service/class names
- External systems (databases, APIs, libraries)
- Feature names

### factDateTs — when to include:

- Always include current date for time-anchored facts
- Use the event date for historical findings
- Skip for timeless knowledge

---

## 5. Graph-Aware Recall

Always use `graphRecall: true` when recalling memories. This activates spreading activation — traversing typed relationship edges (supersedes, caused_by, refines, etc.) to find connected memories that pure vector search misses.

```
recall(query: "...", graphRecall: true)
```

The only exception is quick lookups where speed matters more than depth.

---

## 6. Context Briefing as Default Entry Point

For any skill that needs project context before acting, `context_briefing` is the single best tool. It runs in parallel:

- recall (durable + semantic LTM)
- hybrid_search (keyword + semantic)
- get_patterns
- get_adrs
- search_graph (if files specified)

```
context_briefing(task: "<what you're about to do>", files: [<files if known>])
```

Prefer this over individual calls — it's faster (parallel) and more complete.

---

## 7. Quarantine Awareness

Auto-generated memories (from conversation-analyzer, fact-extractor, session consolidation) go to quarantine. They live 7 days and get deleted if nobody promotes them.

### What skills should know:

- Your explicit `remember()` calls go directly to **durable** — they bypass quarantine
- The consolidation agent's auto-extracted memories go to **quarantine** — they need promotion
- If the user asks about memory quality or wants to triage quarantine: use `review_memories` + `promote_memory`
- The `/reka:end` command reviews quarantine at session end

### Don't worry about:

- Manually promoting memories from within coding/investigation skills
- That's `/reka:end`'s job (plus `review_memories`/`promote_memory` on demand)
- Just make sure YOUR findings are saved via `remember()` (durable path)

---

## Quick Reference Card

```
START:    start_session(initialContext: "...")     <- if not already active
CONTEXT:  context_briefing(task, files)           <- parallel recall+search+patterns+ADRs
RECALL:   recall(query, graphRecall: true)        <- always graphRecall
SAVE:     recall first -> check supersedes -> remember(content, type, tags)
TYPE:     procedure > decision > insight > note   <- choose by longevity need
FACTS:    metadata: { factEntities: [...], factDateTs: N }
END:      remember key findings -> user calls /reka:end to close
```
