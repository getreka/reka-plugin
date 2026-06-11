---
name: obsidian-sync
description: "Bidirectional sync between RAG memories and Obsidian vault. Use when the user wants to export memories to Obsidian, import Obsidian notes into RAG, visualize project knowledge, or sync between the two systems. Triggers on: 'obsidian', 'vault', 'export memories', 'import obsidian', 'sync to obsidian', 'obsidian в rag', 'rag в obsidian', 'візуалізуй пам'ять', 'markdown export', 'index vault', 'load obsidian'."
---

# Obsidian ↔ RAG Sync

Bidirectional sync between RAG project memories and Obsidian vault.

## Direction Detection

Determine the direction from user intent:

- **Export (RAG → Obsidian)**: "export", "show in obsidian", "visualize", "vault export"
- **Import (Obsidian → RAG)**: "import", "index vault", "load from obsidian", "sync notes"
- **Both**: "sync", "bidirectional", "full sync"

---

## Export: RAG → Obsidian

Export RAG memories as Obsidian-compatible Markdown notes with frontmatter, tags, and wikilinks.

### Step 1: Determine vault path

Ask the user if not provided. Default: `~/Obsidian/<project-name>/`

Create directory structure if needed:

```
<vault>/
├── decisions/       # ADRs and architectural decisions
├── insights/        # Learnings, investigation results
├── patterns/        # Reusable patterns
├── procedures/      # Step-by-step how-to knowledge
├── tech-debt/       # Known technical debt
├── context/         # Background context
├── notes/           # General notes
└── _index.md        # Auto-generated vault index
```

### Step 2: Fetch memories

1. `list_memories(limit: 100)` — durable memories
2. `recall(query: "architecture decision pattern insight procedure", limit: 50)` — ranked
3. `review_memories()` — quarantined auto-memories

Deduplicate by memory ID.

### Step 3: Generate Markdown files

For each memory, create a `.md` file:

```markdown
---
id: <memory-id>
type: <decision|insight|pattern|procedure|context|note>
layer: <durable|semantic>
tags: [<tags>]
created: <ISO date>
source: rag-memory
---

# <Title from first line or content summary>

<memory content>

## Related

- [[decisions/related-note]] (supersedes)
```

Place in directory by type. Derive filename from content (lowercase, dashes, dedup).

If Obsidian MCP is available (`mcp__obsidian__write_note`), use it. Otherwise use Write tool.

### Step 4: Generate `_index.md`

```markdown
# <Project> — RAG Knowledge Base

Exported: <date> | Total: <count>

## Decisions (<count>)

- [[decisions/<name>]]
  ...
```

### Incremental sync

Compare file modification times vs memory `updated` timestamps. Only overwrite if newer. Never delete files removed from RAG.

---

## Import: Obsidian → RAG

Parse vault notes and store as RAG memories.

### Step 1: Scan vault

Use `mcp__obsidian__list_directory('/')` if available, else `Glob("**/*.md")` excluding `.obsidian/` and `.trash/`.

### Step 2: Read and parse notes

Use `mcp__obsidian__read_multiple_notes(paths)` (batch 10) or Read tool.

Extract from each note:

- **YAML frontmatter**: `type` → memory type, `tags` → tags, `created` → metadata
- **Content**: strip frontmatter, preserve Markdown
- **Wikilinks**: `[[target]]` → relationship hints

### Step 3: Map types

| Frontmatter `type`         | RAG memory type          |
| -------------------------- | ------------------------ |
| decision, adr              | decision                 |
| pattern                    | insight (tag: pattern)   |
| procedure, how-to, runbook | procedure                |
| tech-debt                  | insight (tag: tech-debt) |
| meeting, note, journal     | note                     |
| research, analysis         | insight                  |
| (no type)                  | insight                  |

### Step 4: Import

Use `batch_remember` (up to 10 per call):

```json
batch_remember({
  "items": [
    {
      "content": "<note content>",
      "type": "<mapped type>",
      "tags": ["obsidian", "<folder>", ...frontmatter tags]
    }
  ]
})
```

### Incremental import

Use `recall("obsidian-import <filename>")` to check for existing imports. Only import new/modified notes.

---

## Report

After either direction, report:

- Vault path
- Counts by type (created, updated, skipped)
- Direction (export/import/sync)

## Language

Respond in the same language the user uses.
