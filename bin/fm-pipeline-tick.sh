#!/usr/bin/env bash
# fm-pipeline-tick.sh - one self-running pipeline step without hand-routing.
#
# The point of the auto pipeline is that finished work does not wait for the
# orchestrator to notice and move it. A tick does, in order:
#
#   1. Sweep expired claims — ticket returns to the ready queue, never lost
#   2. For each task with a trigger (done: or turn-ended), run observable
#      readiness (PR + pr_head). Self-report alone never makes a ticket ready
#   3. Apply the latest unhandled verdict on tickets
#   4. Surface blocked or quota-dead claimers as blocked: (never as silence)
#
# This script does not spawn agents and does not merge. Stage agents claim via
# fm_pipeline_claim_next; merge authority stays with firstmate/captain through
# fm-merge-gate.sh then fm-pr-merge.sh.
#
# Usage: fm-pipeline-tick.sh [--state DIR] [--pipeline-dir DIR]
# Exit: 0 after a complete tick (actions printed); 2 on usage error.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
PIPELINE_DIR="${FM_PIPELINE_DIR_OVERRIDE:-${FM_HOME}/state/pipeline}"

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
    -h|--help)
      sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "usage: fm-pipeline-tick.sh [--state DIR] [--pipeline-dir DIR]" >&2
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
    ready-for-review:*|ready-for-merge:*|returned:*|needs-decision:*) return 0 ;;
  esac
  fm_ready_is_queued "$PIPELINE_DIR" "$task" && return 0
  return 1
}

# --- 2. Observable readiness for triggered tasks ------------------------------

for meta in "$STATE"/*.meta; do
  [ -e "$meta" ] || continue
  task=$(basename "$meta" .meta)
  _fm_tick_has_trigger "$STATE" "$task" || continue
  _fm_tick_already_ready_or_beyond "$STATE" "$task" && continue
  if fm_ready_observables_ok "$STATE" "$task" 2>/dev/null; then
    stage=$(fm_ready_enqueue_from_meta "$STATE" "$PIPELINE_DIR" "$task")
    sha=$(fm_ready_meta_pr_head "$meta")
    printf 'tick: READY %s %s %s\n' "$task" "$stage" "$sha"
  else
    reason=$(fm_ready_observables_ok "$STATE" "$task" 2>&1 >/dev/null || true)
    printf 'tick: NOT-READY %s (%s)\n' "$task" "${reason:-observables failed}"
  fi
done

# --- 3. Apply latest unhandled verdict ----------------------------------------

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

# --- 4. Blocked / out-of-quota claimers ---------------------------------------

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

exit 0
