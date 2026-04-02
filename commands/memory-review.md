---
description: "Review and manage RAG memory health — triage quarantine queue, promote or reject pending memories, check LTM statistics. Triggers on: 'переглянь пам'ять', 'quarantine', 'review memories', 'memory health', 'memory stats', 'promote', 'очисти пам'ять'."
---

# RAG Memory Review

Triage quarantine, promote good memories, reject noise, monitor memory health.

## Why this matters

Auto-generated memories live only 7 days in quarantine. Without review, all automatic learning is lost. Periodic review promotes valuable memories to durable storage.

## Step 1: Session check

```
start_session(initialContext: "memory review and maintenance")
```

## Step 2: Health overview (parallel)

1. `get_project_stats` — collection sizes
2. `review_memories` — quarantine queue
3. `list_memories(limit: 5)` — recent durable memories

```
## Memory Health: {project}

| Collection | Count | Status |
|------------|-------|--------|
| Durable | {N} | {ok/low/high} |
| Quarantine | {N} | {needs review if > 20} |
| Episodic LTM | {N} | ok |
| Semantic LTM | {N} | ok |

Quarantine: {N} pending ({days until oldest expires})
```

## Step 3: Quarantine triage

For each memory:

```
### Memory #{i}: {type} ({confidence}%)
> {content preview}

Source: {auto_conversation / auto_pattern}
Age: {days} days (expires in {7 - days})

**Recommendation:** {promote / reject / skip}
**Reason:** {why}
```

Ask user: "Promote, reject, or skip?"

**Promote:** `promote_memory(memoryId, reason: "human_validated", evidence: "<reason>")`
**Reject:** Delete from quarantine
**Batch mode** (10+ items): show table, let user say "promote 1,3,5 reject 2,4"

## Step 4: Durable quality check

```
list_memories(limit: 20)
```

Look for: duplicates, stale memories, untyped notes that should be procedure/decision.

## Step 5: Save review results

```
remember(
  content: "Memory review: {date}. Quarantine: {N} reviewed, {promoted} promoted. Health: {assessment}",
  type: "note",
  tags: ["memory-review", "maintenance"]
)
```

## Language

Respond in the same language the user uses.
