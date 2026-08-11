#!/usr/bin/env bash
# fm-merge-gate.sh - independent, SHA-bound merge gate for the auto pipeline.
#
# Merge acts on independent review verdicts, never on the pipeline's own green
# and never on the implementer's word. There is no CI on these repos:
# "mergeable" means only "no text conflict" at the forge, so this gate is the
# real quality bar.
#
# A ticket may pass the merge gate only when ALL of the following hold:
#   1. Every required stage has a green verdict bound to the CURRENT PR head SHA
#   2. No required stage has a more recent red/cannot-verify on that same SHA
#   3. The PR head has not moved since those verdicts (stale verdict → refuse)
#   4. Implementer, each reviewer, and the merger are pairwise distinct agents
#   5. No open needs-decision / ask-user finding is pending on the ticket
#
# A red verdict at any stage never reaches this gate with a green path: the
# pipeline returns that work to the implementer first. If a stale green remains
# after the PR moved, this gate still refuses.
#
# Authority boundary: this script never merges by itself and never widens
# captain authority. It prints ok / refuse reasons. Callers that hold merge
# authority (firstmate under yolo, or captain) may then invoke fm-pr-merge.sh.
#
# Usage (library): . bin/fm-merge-gate.sh
# Usage (CLI):     fm-merge-gate.sh <task-id> <current-pr-head-sha> [required-stages]
#                  [--state DIR] [--merger ID] [--pipeline-dir DIR]
#
# Exit: 0 = gate open (ok printed), 1 = refuse (reason on stderr + stdout),
#       2 = usage error.

set -u

_FM_MERGE_GATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-verdict-lib.sh
. "$_FM_MERGE_GATE_DIR/fm-verdict-lib.sh"
# shellcheck source=bin/fm-pipeline-lib.sh
. "$_FM_MERGE_GATE_DIR/fm-pipeline-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$_FM_MERGE_GATE_DIR/fm-pr-lib.sh"

# Collect verdict lines from a status file (oldest → newest).
# $1: status file
_fm_merge_gate_status_lines() {
  local status=$1
  [ -f "$status" ] || return 0
  cat "$status"
}

# 0 if status has an open needs-decision that is not later resolved.
# $1: status file
fm_merge_gate_has_open_decision() {
  local status=$1
  local line open=0
  [ -f "$status" ] || return 1
  while IFS= read -r line; do
    case "$line" in
      needs-decision:*) open=1 ;;
      resolved:*) open=0 ;;
    esac
  done < "$status"
  [ "$open" -eq 1 ]
}

# Find the latest verdict for a stage whose sha matches current_sha.
# Prints the verdict line, or empty if none.
# $1: status file
# $2: stage
# $3: current PR head SHA
fm_merge_gate_latest_verdict_for() {
  local status=$1 stage=$2 current_sha=$3
  local line best=
  [ -f "$status" ] || return 0
  while IFS= read -r line; do
    case "$line" in
      verdict:*)
        if [ "$(fm_verdict_stage "$line")" = "$stage" ] \
          && fm_verdict_sha_matches "$line" "$current_sha"; then
          best=$line
        fi
        ;;
    esac
  done < "$status"
  printf '%s' "$best"
}

# Core gate check. Prints "ok" on success; prints "refuse: <reason>" and returns
# 1 on failure.
# $1: state directory
# $2: task id
# $3: current PR head SHA (must be forge-resolvable 40/64 hex)
# $4: required stages comma-list
# $5: merger agent id (optional; checked for independence when set)
fm_merge_gate_check() {
  local state=$1 task=$2 current_sha=$3 required=$4 merger=${5:-}
  local status="$state/$task.status"
  local meta="$state/$task.meta"
  local stage line outcome reviewer implementer reviewers="" IFS_SAVE

  if ! fm_pr_head_valid "$current_sha"; then
    printf 'refuse: current PR head SHA is not a valid forge head\n'
    return 1
  fi

  if [ ! -f "$status" ]; then
    printf 'refuse: no status file for %s\n' "$task"
    return 1
  fi

  if fm_merge_gate_has_open_decision "$status"; then
    printf 'refuse: open needs-decision — escalate, do not merge\n'
    return 1
  fi

  implementer=$(fm_pipeline_implementer_id "$state" "$task")

  # shellcheck disable=SC2086
  IFS_SAVE=$IFS
  IFS=,
  # shellcheck disable=SC2086
  set -- $required
  IFS=$IFS_SAVE

  for stage in "$@"; do
    [ -n "$stage" ] || continue
    [ "$stage" = merge ] && continue
    line=$(fm_merge_gate_latest_verdict_for "$status" "$stage" "$current_sha")
    if [ -z "$line" ]; then
      # Distinguish "never reviewed" from "reviewed on a different SHA" (stale).
      if grep -q "verdict:.*\[stage=${stage}\]" "$status" 2>/dev/null; then
        printf 'refuse: stale or missing green for stage %s at sha %s\n' \
          "$stage" "$current_sha"
      else
        printf 'refuse: missing verdict for required stage %s at sha %s\n' \
          "$stage" "$current_sha"
      fi
      return 1
    fi
    if ! fm_verdict_is_valid "$line"; then
      printf 'refuse: invalid verdict for stage %s\n' "$stage"
      return 1
    fi
    outcome=$(fm_verdict_outcome "$line")
    case "$outcome" in
      green) ;;
      red)
        printf 'refuse: red verdict at stage %s — return to implementer\n' "$stage"
        return 1
        ;;
      cannot-verify)
        printf 'refuse: cannot-verify at stage %s — escalate\n' "$stage"
        return 1
        ;;
      *)
        printf 'refuse: unknown outcome at stage %s\n' "$stage"
        return 1
        ;;
    esac
    reviewer=$(fm_verdict_reviewer "$line")
    if ! fm_pipeline_roles_distinct "$implementer" "$reviewer" "$merger"; then
      printf 'refuse: independence violation involving %s\n' "$reviewer"
      return 1
    fi
    reviewers="${reviewers:+$reviewers,}$reviewer"
  done

  # Merger must not equal implementer when both known.
  if ! fm_pipeline_roles_distinct "$implementer" "" "$merger"; then
    printf 'refuse: merger must differ from implementer\n'
    return 1
  fi

  printf 'ok\n'
  return 0
}

# CLI entry when executed, not sourced.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$_FM_MERGE_GATE_DIR/.." && pwd)}"
  FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
  STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
  MERGER=
  REQUIRED="code-review,qa,security-review"
  TASK=
  HEAD=
  PIPELINE_DIR=

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --state) STATE=$2; shift 2 ;;
      --merger) MERGER=$2; shift 2 ;;
      --pipeline-dir) PIPELINE_DIR=$2; shift 2 ;;
      --required) REQUIRED=$2; shift 2 ;;
      -h|--help)
        sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
      -*)
        echo "usage: fm-merge-gate.sh <task-id> <current-pr-head-sha> [required]" >&2
        exit 2
        ;;
      *)
        if [ -z "$TASK" ]; then
          TASK=$1
        elif [ -z "$HEAD" ]; then
          HEAD=$1
        else
          REQUIRED=$1
        fi
        shift
        ;;
    esac
  done

  if [ -z "$TASK" ] || [ -z "$HEAD" ]; then
    echo "usage: fm-merge-gate.sh <task-id> <current-pr-head-sha> [required]" >&2
    exit 2
  fi

  # Unused today but reserved so callers can pass pipeline dir without breaking.
  : "${PIPELINE_DIR:=}"

  if result=$(fm_merge_gate_check "$STATE" "$TASK" "$HEAD" "$REQUIRED" "$MERGER"); then
    printf '%s\n' "$result"
    exit 0
  else
    printf '%s\n' "$result" >&2
    printf '%s\n' "$result"
    exit 1
  fi
fi
