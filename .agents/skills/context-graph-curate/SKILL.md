---
name: context-graph-curate
description: >-
  Curate context-graph nodes and edges after a scout report lands, after stow files durable cross-task links, or when completed work becomes future context.
user-invocable: false
metadata:
  internal: true
---

# context-graph-curate

## Trigger

Load after a scout or design report lands, after `/stow` files a durable cross-task link, or when completed work becomes a dependency for future tasks.

## Procedure

1. Open `data/context-graph/graph.jsonl` and `data/context-graph/schema.md` in the active home.
2. Add a node for the new report or document with a one-line summary, tags, `max_lines`, and priority.
3. Add `implements` or `depends-on` edges from the task to its report.
4. Add a `cites` edge when a report depends on another report.
5. Add a `supersedes` edge instead of silently rewriting an obsolete relationship.
6. Keep summaries free of secrets and volatile paths.
7. Run `bin/fm-context-pack.sh --task <related-id>` and confirm that the new node appears when the recipe and budget allow it.

## Do not

- Do not copy captain memory sections into multi-paragraph graph nodes.
- Do not create a second backlog.
- Do not introduce embeddings or vector retrieval for the deterministic v1 graph.
