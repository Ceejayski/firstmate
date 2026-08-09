#!/usr/bin/env bash
# Resolve a minimal task context pack from the active firstmate home's
# data/context-graph seed.
#
# Usage:
#   fm-context-pack.sh --task <id> [--recipe <name>] [-o <path>]
#   fm-context-pack.sh --recipe <name> [-o <path>]
#   fm-context-pack.sh --list-recipes
#
# FM_HOME selects the private home whose graph, recipes, task briefs, and
# project paths are resolved.
# FM_ROOT_OVERRIDE selects the tracked firstmate code root when this wrapper is
# invoked from another home.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

export FM_HOME
exec python3 "$SCRIPT_DIR/fm-context-pack.py" "$@"
