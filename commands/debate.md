---
description: "Run adversarial debates (Tribunal) to analyze complex decisions with multiple AI advocates and a judge. Use when the user wants to compare approaches, debate trade-offs, or make a well-reasoned technical decision. Triggers on: 'дебат', 'tribunal', 'порівняй підходи', 'debate', 'compare approaches', 'pros and cons', 'which is better', 'evaluate options'."
---

## Memory Protocol

This skill follows the RAG Memory Protocol (see `memory-protocol` skill):

- Ensure session is active
- Always save debate verdict to memory
- Check for previous debates on the same topic

# RAG Tribunal Debate

Run structured adversarial debates: AI advocates argue positions, a judge renders a verdict.

## How it works

4 phases:

1. **Framing** — Judge defines evaluation criteria
2. **Arguments** — Advocates argue positions in parallel
3. **Rebuttal** — Advocates counter opponents' claims
4. **Verdict** — Judge scores all positions, recommends winner

## Workflow

### Step 0: Ensure session and check history

```
start_session(initialContext: "tribunal debate: <topic>")
recall(query: "debate tribunal <topic>", graphRecall: true, limit: 3)
```

If previous debate found, ask: "Build on it or start fresh?"

### Step 1: Extract parameters

From user's message, identify:

- **Topic**: The core question
- **Positions**: 2-4 distinct options
- **Context**: Constraints and requirements

### Step 2: Configure and run

```
mcp__plugin_reka_rag__tribunal_debate(
  topic: "<the question>",
  positions: ["Option A", "Option B", "Option C"],
  context: "<user's context>",
  useCodeContext: true,
  autoRecord: false,
  maxRounds: 1
)
```

Inform user before running: "This will run a tribunal debate (~2-3 min). Proceed?"

### Step 3: Present results

```
## Tribunal Verdict: {topic}

**Recommendation:** {verdict.recommendation}
**Confidence:** {verdict.confidence}

### Scores
| Position | Score | Justification |
|----------|-------|---------------|
| {pos1}   | {score}/10 | {justification} |

### Reasoning
{verdict.reasoning}

### Trade-offs
{verdict.tradeoffs}

### Dissent
{verdict.dissent}
```

### Step 4: Save verdict

```
remember(
  content: "DEBATE VERDICT: {topic}\nRecommendation: {recommendation}\nScores: ...\nKey trade-off: ...",
  type: "decision",
  tags: ["debate-verdict", "<topic-tag>"],
  metadata: {
    factEntities: ["<components discussed>"],
    factDateTs: <unix-timestamp>
  }
)
```

Offer: "Save as ADR?" → `record_adr` if requested.

## Language

Respond in the same language the user uses.
