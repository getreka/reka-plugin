---
description: "Architecture-aware code review using RAG context. Compares code against project patterns, ADRs, and best practices. Use after significant changes or before merging. Triggers on: 'review', 'рев'ю', 'перевір код', 'code review', 'check my changes', 'перевір мої зміни'."
---

# RAG Code Review

Review code changes against project patterns, ADRs, and best practices.

## Memory Protocol

This skill follows the RAG Memory Protocol (see `memory-protocol` skill):

- Start session if needed
- Save review findings to memory
- Use `context_briefing` for parallel context loading

## Workflow

### Step 0: Ensure session

```
start_session(initialContext: "code review: <description>")
```

### Step 1: Identify changes

Run `git diff` or `git diff --staged` to see what changed. Identify the changed files.

### Step 2: Load project context (parallel)

```
context_briefing(task: "review <description>", files: [<changed files>])
```

Also load in parallel:

- `get_patterns` — established patterns to check against
- `get_tech_debt` — known debt in the affected area

### Step 3: Review

For each changed file, check against:

- [ ] Follows established architectural patterns (from `get_patterns`)
- [ ] Consistent with existing ADRs (from `get_adrs`)
- [ ] Error handling present (try/catch, logging)
- [ ] No security issues (injection, auth bypass)
- [ ] Proper logging with structured metadata
- [ ] Input validation for new API inputs
- [ ] No hardcoded config values
- [ ] Test coverage for new code paths

Use `search_codebase` to find similar implementations and check consistency.
Use `explain_code(file, startLine, endLine)` for complex sections.

### Step 4: Report

For each finding:

```
## Code Review: {description}

### Critical
- **{file}:{line}** — {issue}. Fix: {how to resolve}

### Warning
- **{file}:{line}** — {issue}. Fix: {how to resolve}

### Suggestion
- **{file}:{line}** — {suggestion}
```

### Step 5: Save review results

```
remember(
  content: "Code review: {description}. {N} critical, {M} warnings, {K} suggestions. Key issues: {summary}",
  type: "insight",
  tags: ["code-review", "<component>"],
  metadata: {
    factEntities: [<reviewed files>],
    factDateTs: <unix-timestamp>
  }
)
```

## Language

Respond in the same language the user uses.
