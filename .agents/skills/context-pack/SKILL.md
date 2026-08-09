---
name: context-pack
description: >-
  Resolve a minimal context pack from the fleet context graph before dispatching a crewmate or scout, or when expanding a brief.
  Prevent full captain.md, learnings.md, and unrelated report dumps that burn tokens.
user-invocable: false
metadata:
  internal: true
---

# context-pack

## Trigger

Load before every crewmate or scout dispatch and whenever a brief would otherwise request whole standing-memory files or several unrelated reports.

## Procedure

1. Choose a recipe or let the tool infer one from the task id and repository.
2. Run `bin/fm-context-pack.sh --task <id> [--recipe <name>] -o data/<id>/context-pack.md` under the active `FM_HOME`.
3. Link `data/<id>/context-pack.md` as the worker's first read, or scaffold the brief with `bin/fm-brief.sh <id> <repo> --context-pack [recipe]`.
4. Paste only the Must read list when the pack itself would be unnecessary overhead.
5. Never paste full `data/captain.md` or `data/learnings.md` content into a worker brief.
6. If the pack trims nodes, do not re-add them without a task-specific reason.

List recipes with `bin/fm-context-pack.sh --list-recipes` instead of relying on a copied inventory.

## Hard rules

- A pack budget is a ceiling, not a target.
- Related reports must not exceed the recipe's `max_reports` value.
- Private captain and learnings paths are always line-bounded by the resolver, even when a graph node omits its cap.
- Project `AGENTS.md` and `DESIGN.md` references should use line caps and targeted searches.
- The active home's `data/context-graph/ARCHITECTURE.md` owns the fleet-local graph architecture and seed integration plan.
