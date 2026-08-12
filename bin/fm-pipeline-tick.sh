#!/usr/bin/env bash
# fm-pipeline-tick.sh - one self-running pipeline step without hand-routing.
#
# The point of the auto pipeline is that finished work does not wait for the
# orchestrator to notice and move it. A tick does, in order:
#
#   1. Sweep expired claims — ticket returns to the ready queue, never lost
#   2. Refresh live forge heads for tickets with pr= (PR can move under review)
#   3. For each task with a trigger (done: or turn-ended), run observable
#      readiness (PR + pr_head). Self-report alone never makes a ticket ready
#   4. Apply the latest unhandled verdict on tickets
#   5. Surface blocked or quota-dead claimers as blocked: (never as silence)
#   6. Dispatch stage agents: claim + standing-spec brief (+ optional spawn)
#
# The watcher runs this on its check cadence so firstmate need not remember.
# Merge authority stays with firstmate/captain through fm-merge-gate.sh then
# fm-pr-merge.sh. Post-merge build verification is a separate ship.
#
# Usage: fm-pipeline-tick.sh [--state DIR] [--pipeline-dir DIR] [--no-dispatch]
# Exit: 0 after a complete tick (actions printed); 2 on usage error.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
PIPELINE_DIR="${FM_PIPELINE_DIR_OVERRIDE:-${FM_HOME}/state/pipeline}"
DO_DISPATCH=1

# shellcheck source=bin/fm-claim-lib.sh
. "$SCRIPT_DIR/fm-claim-lib.sh"
# shellcheck source=bin/fm-verdict-lib.sh
. "$SCRIPT_DIR/fm-verdict-lib.sh"
# shellcheck source=bin/fm-pipeline-lib.sh
. "$SCRIPT_DIR/fm-pipeline-lib.sh"
# shellcheck source=bin/fm-ready-check.sh
. "$SCRIPT_DIR/fm-ready-check.sh"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --state) STATE=$2; shift 2 ;;
    --pipeline-dir) PIPELINE_DIR=$2; shift 2 ;;
    --no-dispatch) DO_DISPATCH=0; shift ;;
    -h|--help)
      sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "usage: fm-pipeline-tick.sh [--state DIR] [--pipeline-dir DIR] [--no-dispatch]" >&2
      exit 2
      ;;
  esac
done

fm_pipeline_init "$PIPELINE_DIR"

# --- 1. Sweep expired claims --------------------------------------------------
while IFS= read -r line; do
  [ -n "$line" ] || continue
  printf 'tick: %s\n' "$line"
done < <(fm_pipeline_sweep "$PIPELINE_DIR")

# --- helpers ------------------------------------------------------------------

_fm_tick_last_verb() {
  local status=$1 line
  [ -f "$status" ] || return 0
  line=$(tail -1 "$status" 2>/dev/null || true)
  case "$line" in
    *:*) printf '%s' "${line%%:*}" ;;
  esac
}

_fm_tick_has_trigger() {
  local state=$1 task=$2
  local status="$state/$task.status"
  local turn="$state/$task.turn-ended"
  local verb

  [ -f "$turn" ] && return 0
  verb=$(_fm_tick_last_verb "$status")
  case "$verb" in
    done|ready-for-review|verdict) return 0 ;;
  esac
  return 1
}

_fm_tick_already_ready_or_beyond() {
  local state=$1 task=$2
  local status="$state/$task.status" line
  [ -f "$status" ] || return 1
  line=$(tail -1 "$status" 2>/dev/null || true)
  case "$line" in
    ready-for-review:*|ready-for-merge:*|returned:*|needs-decision:*|review-dispatched:*) return 0 ;;
  esac
  fm_ready_is_queued "$PIPELINE_DIR" "$task" && return 0
  return 1
}

# --- 2. Live forge head refresh for PR-bearing tickets ------------------------

for meta in "$STATE"/*.meta; do
  [ -e "$meta" ] || continue
  task=$(basename "$meta" .meta)
  pr=$(grep '^pr=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  [ -n "$pr" ] || continue
  if live=$(fm_pipeline_refresh_pr_head "$STATE" "$task" "$PIPELINE_DIR" 2>/dev/null); then
    recorded=$(fm_ready_meta_pr_head "$meta")
    # refresh rewrites meta; re-read for comparison is noisy — print when ready marker updated
    if [ -n "$live" ]; then
      printf 'tick: HEAD %s %s\n' "$task" "$live"
    fi
  fi
done

# --- 3. Observable readiness for triggered tasks ------------------------------

for meta in "$STATE"/*.meta; do
  [ -e "$meta" ] || continue
  task=$(basename "$meta" .meta)
  _fm_tick_has_trigger "$STATE" "$task" || continue
  _fm_tick_already_ready_or_beyond "$STATE" "$task" && continue
  if fm_ready_observables_ok "$STATE" "$task" 2>/dev/null; then
    if stage=$(fm_ready_enqueue_from_meta "$STATE" "$PIPELINE_DIR" "$task"); then
      sha=$(fm_ready_meta_pr_head "$STATE/$task.meta")
      printf 'tick: READY %s %s %s\n' "$task" "$stage" "$sha"
    else
      printf 'tick: BLOCKED-PATHS %s\n' "$task"
    fi
  else
    reason=$(fm_ready_observables_ok "$STATE" "$task" 2>&1 >/dev/null || true)
    printf 'tick: NOT-READY %s (%s)\n' "$task" "${reason:-observables failed}"
  fi
done

# --- 4. Apply latest unhandled verdict ----------------------------------------

for status in "$STATE"/*.status; do
  [ -e "$status" ] || continue
  task=$(basename "$status" .status)
  line=
  while IFS= read -r l; do
    case "$l" in
      verdict:*) line=$l ;;
    esac
  done < "$status"
  [ -n "$line" ] || continue

  applied=0
  seen_verdict=0
  while IFS= read -r l; do
    case "$l" in
      verdict:*)
        if [ "$l" = "$line" ]; then
          seen_verdict=1
        fi
        ;;
      ready-for-review:*|ready-for-merge:*|returned:*|needs-decision:*)
        if [ "$seen_verdict" -eq 1 ]; then
          applied=1
        fi
        ;;
    esac
  done < "$status"
  [ "$applied" -eq 0 ] || continue

  required=$(fm_ready_field "$PIPELINE_DIR" "$task" required 2>/dev/null || true)
  if fm_pipeline_apply_verdict "$PIPELINE_DIR" "$STATE" "$task" "$line" "" "$required"; then
    printf 'tick: APPLIED %s %s\n' "$task" "$(fm_verdict_outcome "$line")"
  fi
done

# --- 5. Blocked / out-of-quota claimers ---------------------------------------

for claim in "$PIPELINE_DIR"/*.claim; do
  [ -e "$claim" ] || continue
  task=$(basename "$claim" .claim)
  holder=$(fm_claim_holder "$PIPELINE_DIR" "$task")
  [ -n "$holder" ] || continue
  for candidate in "$STATE/$holder.status" "$STATE/claimer-$holder.status"; do
    if [ -f "$candidate" ]; then
      if out=$(fm_pipeline_release_if_claimer_blocked \
        "$PIPELINE_DIR" "$STATE" "$task" "$candidate"); then
        printf 'tick: %s\n' "$out"
      fi
      break
    fi
  done
done

# --- 6. Dispatch stage agents (claim + standing brief [+ spawn]) --------------

if [ "$DO_DISPATCH" -eq 1 ] && [ -x "$SCRIPT_DIR/fm-pipeline-dispatch.sh" ]; then
  # Default no-spawn inside tick when FM_PIPELINE_AUTO_SPAWN=0; otherwise spawn.
  dispatch_flags=(--state "$STATE" --pipeline-dir "$PIPELINE_DIR" --max 3)
  if [ "${FM_PIPELINE_AUTO_SPAWN:-1}" = "0" ]; then
    dispatch_flags+=(--no-spawn)
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf 'tick: %s\n' "$line"
  done < <("$SCRIPT_DIR/fm-pipeline-dispatch.sh" "${dispatch_flags[@]}" 2>&1 || true)
fi

exit 0
