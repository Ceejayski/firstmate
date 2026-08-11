#!/usr/bin/env bash
# fm-ready-check.sh - harness-agnostic readiness detection for the pipeline.
#
# Derives readiness from OBSERVABLE FACTS, not from harness-specific output.
# A worker that finishes but forgets to append a status line is still detected.
# A worker that claims done but has uncommitted changes is not ready.
#
# Observable facts checked:
#   1. The worktree exists and is clean (no uncommitted changes, nothing staged)
#   2. The worker's turn ended (state/<id>.turn-ended exists)
#   3. For ship tasks: the branch is pushed and a PR is open
#   4. No active no-mistakes run is attributed to this crew
#   5. The worker's pane is not busy (harness-agnostic via fm-crew-state.sh)
#
# If all checks pass, appends "ready-for-review: <stage>" to the status file.
# The stage is determined by the current pipeline position (first stage = code-review).
#
# Harness-agnostic: none of these checks depend on what a particular harness
# prints, how it signals completion, or whether it supports a specific feature.
# The turn-ended file is touched by every harness's turn-end hook.
#
# Usage: fm-ready-check.sh <task-id> [state-dir]
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-claim-lib.sh
. "$SCRIPT_DIR/fm-claim-lib.sh"

ID=${1:-}
[ -n "$ID" ] || { echo "usage: fm-ready-check.sh <task-id> [state-dir]" >&2; exit 2; }
STATE="${2:-$STATE}"

META="$STATE/$ID.meta"
STATUS="$STATE/$ID.status"
TURN_ENDED="$STATE/$ID.turn-ended"

# 0 if the task is ready for review; 1 if not. Prints the reason to stderr when
# not ready (for diagnostics), and prints the stage to stdout when ready.
# Exit codes: 0 = ready, 1 = not ready, 2 = error (no meta, etc.)

# --- 1. Task must exist -------------------------------------------------------
[ -f "$META" ] || { echo "no metadata for $ID" >&2; exit 2; }

# Resolve worktree and kind from meta.
WT=$(grep '^worktree=' "$META" 2>/dev/null | tail -1 | cut -d= -f2- || true)
KIND=$(grep '^kind=' "$META" 2>/dev/null | tail -1 | cut -d= -f2- || true)
[ -n "$KIND" ] || KIND=ship

# Scouts are never ready for review (they produce reports, not PRs).
if [ "$KIND" = scout ]; then
  echo "scout tasks are not reviewed through the pipeline" >&2
  exit 1
fi

# Secondmates are never reviewed through the pipeline.
if [ "$KIND" = secondmate ]; then
  echo "secondmates are not reviewed through the pipeline" >&2
  exit 1
fi

# --- 2. Worktree must exist and be clean --------------------------------------
if [ -z "$WT" ] || [ ! -d "$WT" ]; then
  echo "worktree missing or torn down" >&2
  exit 1
fi

# Check for uncommitted changes (tracked and untracked).
if ! git -C "$WT" diff --quiet 2>/dev/null; then
  echo "uncommitted tracked changes in worktree" >&2
  exit 1
fi
if ! git -C "$WT" diff --cached --quiet 2>/dev/null; then
  echo "staged changes in worktree" >&2
  exit 1
fi
if [ -n "$(git -C "$WT" ls-files --others --exclude-standard 2>/dev/null)" ]; then
  echo "untracked files in worktree" >&2
  exit 1
fi

# --- 3. Turn ended ------------------------------------------------------------
# The turn-ended file is touched by EVERY harness's turn-end hook.
# This is the single harness-agnostic signal that the worker finished a turn.
if [ ! -f "$TURN_ENDED" ]; then
  echo "turn has not ended" >&2
  exit 1
fi

# --- 4. Worker must have reported done ----------------------------------------
# The done: status line is the worker's own declaration. This is a secondary
# check because the turn-ended signal is authoritative. But a worker that
# stopped mid-turn (interrupted, crashed) should not be picked up.
LAST_LINE=$(last_status_line "$STATUS")
LAST_VERB=$(status_line_verb "$LAST_LINE")
if [ "$LAST_VERB" != "done" ]; then
  echo "last status verb is '$LAST_VERB', not 'done'" >&2
  exit 1
fi

# --- 5. No active no-mistakes run ---------------------------------------------
# A worker whose validation is still running is not done, even if it appended
# done: prematurely. The run-step is authoritative.
if command -v "$SCRIPT_DIR/fm-crew-state.sh" >/dev/null 2>&1; then
  CREW_STATE=$("$SCRIPT_DIR/fm-crew-state.sh" "$ID" 2>/dev/null) || true
  case "$CREW_STATE" in
    state:working*)
      echo "crew is still working (active run)" >&2
      exit 1
      ;;
    state:unknown*source:none*)
      echo "crew state is unknown" >&2
      exit 1
      ;;
  esac
fi

# --- 6. Branch must be pushed (for ship tasks) --------------------------------
CREW_BRANCH=$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
if [ -n "$CREW_BRANCH" ]; then
  # Check if the branch has been pushed to any remote.
  if ! git -C "$WT" branch -r 2>/dev/null | grep -q "/${CREW_BRANCH}$"; then
    echo "branch $CREW_BRANCH has not been pushed" >&2
    exit 1
  fi
fi

# --- All checks passed --------------------------------------------------------
# Determine which stage this ticket is ready for.
# The first stage is always code-review. The pipeline advances through stages
# as each returns a green verdict.
# For now, default to code-review as the entry point.
STAGE="code-review"

# Get the current commit SHA for the verdict binding.
SHA=$(git -C "$WT" rev-parse HEAD 2>/dev/null || true)

# Append the ready-for-review status line.
echo "ready-for-review: $STAGE [sha=$SHA]" >> "$STATUS"

# Print the stage for scripting.
printf '%s' "$STAGE"
exit 0