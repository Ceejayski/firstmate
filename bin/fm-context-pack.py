#!/usr/bin/env python3
"""Resolve a minimal context pack from the active home's context graph.

Usage:
  fm-context-pack.py --task <id>
  fm-context-pack.py --recipe firstmate-ship
  fm-context-pack.py --task <id> --recipe firstmate-ship
  fm-context-pack.py --list-recipes

The active graph and recipes live under $FM_HOME/data/context-graph.
Exit 0 on successful pack emission, including a budget-trimmed pack.
Exit 2 on invalid usage or missing graph data.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path


CODE_ROOT = Path(__file__).resolve().parents[1]
HOME_ROOT = Path(os.environ.get("FM_HOME", CODE_ROOT)).resolve()
GRAPH_DIR = HOME_ROOT / "data" / "context-graph"
GRAPH = GRAPH_DIR / "graph.jsonl"
RECIPES = GRAPH_DIR / "recipes"
BOUNDED_PRIVATE_PATHS = {"data/captain.md", "data/learnings.md"}
PRIVATE_PATH_MAX_LINES = 20


def load_graph(path: Path) -> tuple[dict[str, dict], list[dict]]:
    nodes: dict[str, dict] = {}
    edges: list[dict] = []
    if not path.is_file():
        raise SystemExit(f"error: graph missing: {path}")
    for line_number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError as exc:
            raise SystemExit(f"error: invalid graph JSON at {path}:{line_number}: {exc}") from exc
        op = obj.get("op")
        if op == "node":
            nodes[obj["id"]] = obj
        elif op == "edge":
            edges.append(obj)
    return nodes, edges


def parse_recipe(path: Path) -> dict:
    """Parse the fleet seed's minimal YAML subset."""
    text = path.read_text(encoding="utf-8")
    data: dict = {
        "name": path.stem,
        "always": [],
        "forbid": [],
        "max_tokens": 8000,
        "max_reports": 1,
        "max_docs": 2,
        "notes": "",
    }
    current_list: str | None = None
    notes_lines: list[str] = []
    in_notes = False
    for line in text.splitlines():
        if in_notes:
            if line.startswith("  ") or line.startswith("\t") or not line.strip():
                notes_lines.append(line[2:] if line.startswith("  ") else line)
                continue
            in_notes = False
        match = re.match(r"^([a-z_]+):\s*(.*)$", line)
        if not match:
            if current_list and line.strip().startswith("- "):
                data.setdefault(current_list, []).append(line.strip()[2:].strip())
            continue
        key, value = match.group(1), match.group(2).strip()
        current_list = None
        if key == "notes":
            in_notes = True
            if value not in ("|", ">", ""):
                notes_lines.append(value)
            continue
        if not value:
            current_list = key
            data[key] = []
            continue
        if key in ("max_tokens", "max_reports", "max_docs"):
            data[key] = int(value)
        else:
            data[key] = value
    if notes_lines:
        data["notes"] = "\n".join(notes_lines).strip()
    return data


def estimate_tokens(path: Path | None, max_lines: int | None) -> int:
    if path is None or not path.is_file():
        return 80
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return 80
    if max_lines and max_lines > 0:
        text = "\n".join(text.splitlines()[:max_lines])
    return max(40, len(text) // 4)


def bounded_node(node: dict) -> dict:
    """Fail safe against graph nodes requesting whole private memory files."""
    if node.get("path") not in BOUNDED_PRIVATE_PATHS:
        return node
    bounded = dict(node)
    configured = int(bounded.get("max_lines") or PRIVATE_PATH_MAX_LINES)
    bounded["max_lines"] = min(configured, PRIVATE_PATH_MAX_LINES)
    return bounded


def resolve_task_repo(task_id: str, nodes: dict[str, dict]) -> str | None:
    node = nodes.get(f"task:{task_id}")
    if node and node.get("repo") and node["repo"] != "-":
        return node["repo"]
    brief = HOME_ROOT / "data" / task_id / "brief.md"
    if brief.is_file():
        text = brief.read_text(encoding="utf-8", errors="replace")[:2000]
        if "projects/spoodifier-ai" in text or "repo: spoodifier-ai" in text or "of spoodifier-ai" in text:
            return "spoodifier-ai"
        if "of my-repo" in text or "projects/my-repo" in text:
            return "my-repo"
        if "firstmate" in text and "shared" in text:
            return "firstmate"
    return None


def pick_recipe(task_id: str | None, recipe_name: str | None, repo: str | None, kind_hint: str | None) -> Path:
    if recipe_name:
        path = RECIPES / f"{recipe_name}.yaml"
        if not path.is_file():
            raise SystemExit(f"error: unknown recipe {recipe_name}")
        return path
    name = "brain-scout"
    if kind_hint == "design" or (task_id and "design" in task_id):
        name = "design-scout"
    elif kind_hint == "scout" or (task_id and any(token in task_id for token in ("arch", "scout", "audit", "research"))):
        name = "cost-scout" if task_id and "cost" in task_id else "brain-scout"
    elif repo == "spoodifier-ai":
        name = "spoodifier-ai-frontend-ship"
    elif repo == "my-repo":
        name = "my-repo-server-ship"
    elif repo == "firstmate" or (task_id and task_id.startswith("fleet-")):
        name = "firstmate-ship"
    path = RECIPES / f"{name}.yaml"
    if not path.is_file():
        raise SystemExit(f"error: recipe file missing {path}")
    return path


def neighborhood(task_id: str, edges: list[dict]) -> list[str]:
    task_node = f"task:{task_id}"
    related: list[str] = []
    for edge in edges:
        if edge.get("from") == task_node and edge.get("rel") in ("depends-on", "implements", "cites"):
            related.append(edge["to"])
        if edge.get("to") == task_node and edge.get("rel") == "blocked-by":
            related.append(edge["from"])
    return related


def build_pack(task_id: str | None, recipe: dict, nodes: dict[str, dict], edges: list[dict]) -> str:
    max_tokens = int(recipe.get("max_tokens") or 8000)
    selected: list[dict] = []
    seen: set[str] = set()

    def add_id(node_id: str) -> None:
        if node_id in seen:
            return
        node = nodes.get(node_id)
        if not node:
            if ":" not in node_id:
                return
            node = {
                "id": node_id,
                "type": "missing",
                "summary": f"(missing graph node {node_id})",
                "priority": 10,
            }
        seen.add(node_id)
        selected.append(bounded_node(node))

    for node_id in recipe.get("always") or []:
        add_id(node_id)

    report_count = 0
    doc_count = 0
    max_reports = int(recipe.get("max_reports") or 1)
    max_docs = int(recipe.get("max_docs") or 2)
    if task_id:
        add_id(f"task:{task_id}")
        for node_id in neighborhood(task_id, edges):
            node_type = nodes.get(node_id, {}).get("type")
            if node_type == "report":
                if report_count >= max_reports:
                    continue
                report_count += 1
            if node_type == "doc":
                if doc_count >= max_docs:
                    continue
                doc_count += 1
            add_id(node_id)

    def node_cost(node: dict) -> int:
        relative = node.get("path")
        path = Path(relative) if relative and str(relative).startswith("/") else (HOME_ROOT / relative if relative else None)
        if relative and not (HOME_ROOT / relative).is_file() and relative.startswith("projects/"):
            return max(60, int(node.get("max_lines") or 40) * 8)
        return estimate_tokens(path, node.get("max_lines"))

    selected.sort(key=lambda node: int(node.get("priority") or 50), reverse=True)
    kept: list[dict] = []
    total = 0
    trimmed: list[str] = []
    for node in selected:
        cost = node_cost(node)
        if total + cost > max_tokens:
            trimmed.append(node.get("id", "?"))
            continue
        kept.append(node)
        total += cost

    lines = [
        "# Context pack",
        "",
        f"- recipe: `{recipe.get('name')}`",
        f"- task: `{task_id or '-'}`",
        f"- budget: **{max_tokens}** estimated tokens; pack uses about **{total}**",
        "- graph: `data/context-graph/graph.jsonl`",
        "",
        "## Must read (in order, respect max lines)",
        "",
    ]
    for index, node in enumerate(kept, 1):
        path = node.get("path") or "-"
        max_lines = node.get("max_lines")
        line_cap = f"; max {max_lines} lines" if max_lines else ""
        lines.append(f"{index}. **{node.get('id')}** ({node.get('type')}) - {node.get('summary', '')}")
        lines.append(f"   - path: `{path}`{line_cap}")
        lines.append("")

    lines.extend(
        [
            "## Do not read for this task",
            "",
            "- Full `data/captain.md`; use only line-bounded live rules listed above.",
            "- Full `data/learnings.md`.",
            "- Unrelated `data/*/report.md` directories not listed in this pack.",
            "- Random prior task briefs.",
        ]
    )
    for token in recipe.get("forbid") or []:
        lines.append(f"- forbid token: `{token}`")
    lines.append("")

    if trimmed:
        lines.extend(["## Trimmed for budget (lower priority)", ""])
        for node_id in trimmed:
            lines.append(f"- `{node_id}`")
        lines.append("")

    notes = (recipe.get("notes") or "").strip()
    if notes:
        lines.extend(["## Recipe notes", "", notes, ""])

    command = "bin/fm-context-pack.sh"
    if task_id:
        command += f" --task {task_id}"
    command += f" --recipe {recipe.get('name')}"
    lines.extend(
        [
            "## Operator",
            "",
            f"Regenerate: `{command}`",
            "Curate the graph after new reports by loading the `context-graph-curate` skill.",
            "",
        ]
    )
    return "\n".join(lines)


def main() -> None:
    parser = argparse.ArgumentParser(description="Build a minimal context pack from the active home's fleet graph")
    parser.add_argument("--task", help="Task id")
    parser.add_argument("--recipe", help="Recipe name under data/context-graph/recipes")
    parser.add_argument("--repo", help="Force the repository hint")
    parser.add_argument("--kind", help="Hint: ship, scout, or design")
    parser.add_argument("--list-recipes", action="store_true")
    parser.add_argument("--json", action="store_true", help="Emit a machine-readable summary")
    parser.add_argument("-o", "--output", help="Write pack Markdown to this path")
    args = parser.parse_args()

    if args.list_recipes:
        if not RECIPES.is_dir():
            raise SystemExit(f"error: recipes missing: {RECIPES}")
        for path in sorted(RECIPES.glob("*.yaml")):
            print(path.stem)
        return
    if not args.task and not args.recipe:
        parser.error("need --task and/or --recipe, or --list-recipes")

    nodes, edges = load_graph(GRAPH)
    repo = args.repo or (resolve_task_repo(args.task, nodes) if args.task else None)
    recipe = parse_recipe(pick_recipe(args.task, args.recipe, repo, args.kind))
    pack = build_pack(args.task, recipe, nodes, edges)
    if args.output:
        output = Path(args.output)
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(pack, encoding="utf-8")
        print(f"wrote {output}", file=sys.stderr)
    if args.json:
        print(json.dumps({"recipe": recipe.get("name"), "task": args.task, "repo": repo, "chars": len(pack)}))
    else:
        sys.stdout.write(pack)


if __name__ == "__main__":
    main()
