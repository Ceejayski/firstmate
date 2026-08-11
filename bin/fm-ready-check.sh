#!/usr/bin/env bash
# fm-ready-check.sh - third-party observable readiness for the auto pipeline.
#
# A status line may TRIGGER this check; it must never BE the readiness check.
# Four workers reported `done:` today with nothing a reviewer could reach
# (local-only branch, pushed-no-PR, worktree-only commits). An automatic
# claimer that trusted `done:` would have claimed invisible work.
#
# Readiness is derived only from facts a third party can verify:
#   1. meta records pr=<url> — an open PR a reviewer can open
#   2. meta records pr_head=<sha> — a resolvable forge head (40/64 hex)
#   3. when a worktree is still present, its HEAD matches pr_head (optional
#      consistency check; missing worktree does not fail if pr+pr_head exist)
#
# Not readiness criteria (may be used by the tick as a *trigger* only):
#   - last status verb is done:
#   - turn-ended marker
#   - worker self-report of any kind
#
# When ready (CLI), enqueues the ticket for the first required stage
# (surface-based) and appends ready-for-review: to the status file.
#
# Library (source): defines fm_ready_* helpers only.
# CLI: fm-ready-check.sh <task-id> [state-dir]
# Exit: 0 = ready (stage printed), 1 = not ready (reason on stderr), 2 = error

# shellcheck disable=SC2034
_FM_READY_CHECK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-claim-lib.sh
. "$_FM_READY_CHECK_DIR/fm-claim-lib.sh"
# shellcheck source=bin/fm-pipeline-lib.sh
. "$_FM_READY_CHECK_DIR/fm-pipeline-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$_FM_READY_CHECK_DIR/fm-pr-lib.sh"

# Read pr= from meta. Empty if absent.
fm_ready_meta_pr() {
  local meta=$1
  [ -f "$meta" ] || return 0
  grep '^pr=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# Read pr_head= from meta. Empty if absent.
fm_ready_meta_pr_head() {
  local meta=$1
  [ -f "$meta" ] || return 0
  grep '^pr_head=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# 0 if the task is observably ready for review by a third party.
# Prints reason on stderr when not ready.
# $1: state dir
# $2: task id
fm_ready_observables_ok() {
  local state=$1 task=$2
  local meta="$state/$task.meta"
  local pr head wt kind wt_head

  [ -f "$meta" ] || { echo "no metadata for $task" >&2; return 2; }

  kind=$(grep '^kind=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  [ -n "$kind" ] || kind=ship
  if [ "$kind" = scout ] || [ "$kind" = secondmate ]; then
    echo "$kind tasks are not reviewed through the pipeline" >&2
    return 1
  fi

  pr=$(fm_ready_meta_pr "$meta")
  if [ -z "$pr" ]; then
    echo "no open PR recorded in meta (pr=) — not third-party reachable" >&2
    return 1
  fi

  head=$(fm_ready_meta_pr_head "$meta")
  if [ -z "$head" ]; then
    echo "no resolvable PR head in meta (pr_head=)" >&2
    return 1
  fi
  if ! fm_pr_head_valid "$head"; then
    echo "pr_head is not a valid forge SHA: $head" >&2
    return 1
  fi

  # Optional consistency: if the worktree still exists, its HEAD must match.
  wt=$(grep '^worktree=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  if [ -n "$wt" ] && [ -d "$wt" ]; then
    wt_head=$(git -C "$wt" rev-parse HEAD 2>/dev/null || true)
    if [ -n "$wt_head" ] && [ "$wt_head" != "$head" ]; then
      echo "worktree HEAD $wt_head does not match pr_head $head" >&2
      return 1
    fi
  fi

  return 0
}

# Enqueue a ready ticket from observables. Caller must have verified
# fm_ready_observables_ok. Prints the first stage.
# $1: state dir
# $2: pipeline dir
# $3: task id
fm_ready_enqueue_from_meta() {
  local state=$1 pipeline_dir=$2 task=$3
  local meta="$state/$task.meta"
  local status="$state/$task.status"
  local pr sha required paths stage

  pr=$(fm_ready_meta_pr "$meta")
  sha=$(fm_ready_meta_pr_head "$meta")
  required=$(grep '^required_stages=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  if [ -z "$required" ]; then
    paths=$(grep '^changed_paths=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    required=$(fm_pipeline_required_stages "$paths")
  fi
  stage=$(fm_pipeline_first_required "$required")

  fm_pipeline_init "$pipeline_dir"
  fm_ready_enqueue "$pipeline_dir" "$task" "$stage" "$sha" "$required" "$pr"
  echo "ready-for-review: $stage [sha=$sha] [required=$required] [pr=$pr]" >> "$status"
  printf '%s' "$stage"
}

# --- CLI only when executed, not when sourced ---------------------------------
# Guard with BASH_SOURCE so sourcing defines helpers without running the CLI.
# Avoid a bare `return` here: under `shellcheck -x` a sourced return is treated
# as leaving the caller, marking the rest of the tick script unreachable.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -u

  FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$_FM_READY_CHECK_DIR/.." && pwd)}"
  FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
  STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
  PIPELINE_DIR="${FM_PIPELINE_DIR_OVERRIDE:-${FM_HOME}/state/pipeline}"

  ID=${1:-}
  [ -n "$ID" ] || { echo "usage: fm-ready-check.sh <task-id> [state-dir]" >&2; exit 2; }
  STATE="${2:-$STATE}"

  # Capture rc before any if/! inversion — `if ! cmd; then rc=$?` always sees 0.
  fm_ready_observables_ok "$STATE" "$ID"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    exit "$rc"
  fi

  STAGE=$(fm_ready_enqueue_from_meta "$STATE" "$PIPELINE_DIR" "$ID")
  printf '%s' "$STAGE"
  exit 0
fi
