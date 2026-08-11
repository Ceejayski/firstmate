#!/usr/bin/env bash
# fm-pipeline-lib.sh - pipeline stage tracking and transition management.
#
# Ties claim, verdict, and readiness into one pipeline lifecycle.
# Harness-agnostic: operates on status files, claim files, and observable
# repo state. No dependency on what any harness prints or supports.
#
# The pipeline flow:
#   implementer finishes -> ready-for-review (code-review)
#   reviewer CLAIMS -> review -> verdict: green|red|cannot-verify
#     green -> ready-for-review (qa)
#     red -> back to implementer
#     cannot-verify -> escalation
#   ...repeat for qa, security-review...
#   last green -> ready-for-merge
#
# Usage: . bin/fm-pipeline-lib.sh

# shellcheck source=bin/fm-claim-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-claim-lib.sh"
# shellcheck source=bin/fm-verdict-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-verdict-lib.sh"

# Directory for pipeline state (claim files, ready queue markers).
# Defaults to $FM_HOME/state/pipeline.
FM_PIPELINE_DIR_DEFAULT="${FM_HOME:-$HOME/.firstmate}/state/pipeline"

# The four review stages in order. Each must be completed before the next begins.
FM_PIPELINE_STAGES="code-review qa security-review"

# --- pipeline directory management --------------------------------------------

# Ensure the pipeline directory exists.
# $1: pipeline directory (optional; defaults to FM_PIPELINE_DIR_DEFAULT)
fm_pipeline_init() {
  local pipeline_dir=${1:-$FM_PIPELINE_DIR_DEFAULT}
  mkdir -p "$pipeline_dir"
}

# --- stage transitions --------------------------------------------------------

# Advance a ticket to the next stage after a green verdict.
# Dequeues from the current stage, enqueues for the next stage.
# If the next stage is "merge", appends "ready-for-merge" to the status file.
# $1: pipeline directory
# $2: task id
# $3: current stage
# $4: commit SHA
fm_pipeline_advance() {
  local pipeline_dir=$1 task=$2 current_stage=$3 sha=$4
  local next_stage

  next_stage=$(fm_verdict_next_stage "$current_stage") || return 1

  # Remove from current ready queue
  fm_ready_dequeue "$pipeline_dir" "$task"

  if [ "$next_stage" = merge ]; then
    # All review stages passed. Signal ready for merge.
    echo "ready-for-merge: all review stages passed [sha=$sha]" >> "${FM_HOME:-$HOME/.firstmate}/state/$task.status"
    return 0
  fi

  # Enqueue for the next review stage
  fm_ready_enqueue "$pipeline_dir" "$task" "$next_stage" "$sha"
  echo "ready-for-review: $next_stage [sha=$sha]" >> "${FM_HOME:-$HOME/.firstmate}/state/$task.status"

  return 0
}

# Return a ticket to the implementer after a red verdict.
# Removes from all ready queues, appends "returned: <stage> red" to the status.
# $1: pipeline directory
# $2: task id
# $3: stage that returned red
# $4: findings summary (optional)
fm_pipeline_return() {
  local pipeline_dir=$1 task=$2 stage=$3 findings=${4:-}
  local status="${FM_HOME:-$HOME/.firstmate}/state/$task.status"

  # Remove from ready queue
  fm_ready_dequeue "$pipeline_dir" "$task"

  # Release any active claim
  fm_claim_release "$pipeline_dir" "$task" "$(fm_claim_holder "$pipeline_dir" "$task")" 2>/dev/null || true

  local line="returned: $stage returned red"
  [ -n "$findings" ] && line="$line [findings=$findings]"
  echo "$line" >> "$status"
}

# --- pipeline status query ----------------------------------------------------

# What stage is a ticket currently in? Reads from the most recent
# ready-for-review or verdict line in the status file.
# Prints the stage name, or empty if not in the pipeline.
# $1: state directory
# $2: task id
fm_pipeline_current_stage() {
  local state=$1 task=$2
  local status="$state/$task.status"
  local line stage

  [ -f "$status" ] || return 0

  # Read the status file in reverse (most recent first) to find the current stage.
  while IFS= read -r line; do
    case "$line" in
      *ready-for-review:*)
        stage=$(printf '%s' "$line" | grep -o 'ready-for-review: [^ ]*' | cut -d' ' -f2-)
        [ -n "$stage" ] && { printf '%s' "$stage"; return 0; }
        ;;
      *ready-for-merge:*)
        printf 'merge'
        return 0
        ;;
      *returned:*)
        printf 'returned'
        return 0
        ;;
      *verdict:*)
        stage=$(printf '%s' "$line" | grep -o '\[stage=[^]]*\]' | sed 's/\[stage=//;s/\]//')
        [ -n "$stage" ] && { printf '%s' "$stage"; return 0; }
        ;;
    esac
  done < <(tail -r "$status" 2>/dev/null || tail -100 "$status" | cat -n | sort -rn | cut -f2-)

  return 0
}

# --- pipeline claim and review -------------------------------------------------

# Attempt to claim the next available ticket at a given stage.
# Prints "<task-id> <sha>" on success, or nothing if no ticket is available.
# $1: pipeline directory
# $2: stage (code-review, qa, security-review)
# $3: claimer agent id
# $4: TTL seconds (optional)
fm_pipeline_claim_next() {
  local pipeline_dir=$1 stage=$2 claimer=$3 ttl=${4:-$FM_CLAIM_TTL_DEFAULT}
  local task sha

  while IFS=' ' read -r task sha; do
    [ -n "$task" ] || continue
    if fm_claim_acquire "$pipeline_dir" "$task" "$claimer" "$sha" "$stage" "$ttl"; then
      printf '%s %s\n' "$task" "$sha"
      return 0
    fi
  done < <(fm_ready_list "$pipeline_dir" "$stage")

  return 1
}

# --- pipeline health ----------------------------------------------------------

# Sweep the pipeline for expired claims and return them to the ready queue.
# $1: pipeline directory
fm_pipeline_sweep() {
  local pipeline_dir=$1
  fm_claim_sweep "$pipeline_dir"
}

# Count tickets at each stage.
# Prints "stage:<count>" lines.
# $1: pipeline directory
fm_pipeline_counts() {
  local pipeline_dir=$1 stage count
  for stage in $FM_PIPELINE_STAGES; do
    count=$(fm_ready_list "$pipeline_dir" "$stage" | wc -l | tr -d ' ')
    printf '%s:%s\n' "$stage" "$count"
  done
}

# --- independence enforcement --------------------------------------------------

# 0 if the implementer and reviewer are different agents. This is the
# independence guard: the pipeline must never let the same agent that
# implemented a ticket also review it.
# $1: state directory
# $2: task id
# $3: reviewer agent id
fm_pipeline_independent() {
  local state=$1 task=$2 reviewer=$3
  local meta="$state/$task.meta"
  local implementer

  [ -f "$meta" ] || return 0  # Can't verify, allow (fail open with warning)

  # The implementer is the harness recorded in meta.
  # For independence, we check that the reviewer is a different agent.
  # In practice, the reviewer's agent id should be different from the
  # implementer's harness+model combination.
  implementer=$(grep '^harness=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)

  # If the reviewer is the same harness as the implementer AND the same model,
  # that's a violation. But for now, we just check that the harness differs.
  # A more sophisticated check would also verify the model.
  if [ "$implementer" = "$reviewer" ]; then
    echo "independence violation: implementer harness $implementer matches reviewer $reviewer" >&2
    return 1
  fi
  return 0
}