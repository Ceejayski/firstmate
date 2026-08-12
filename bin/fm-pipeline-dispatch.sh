#!/usr/bin/env bash
# fm-pipeline-dispatch.sh - claim a ready stage ticket, compose the standing
# reviewer brief, and optionally spawn an independent scout reviewer.
#
# This is the gap between the claim/verdict library and a running pipeline:
# something must call the claim primitive under independence, compose the brief
# from the brain's standing spec (via fm-review-brief.sh), and run a stage agent.
#
# Harness-agnostic primitives; spawn uses the configured review harness
# (FM_PIPELINE_REVIEW_HARNESS, else config/crew-harness, else blocked — never
# silent). Independence always enforced (empty implementer refuses). Live forge
# head is refreshed before the claim SHA is bound.
#
# Does not merge. Does not answer ask-user. Post-merge build verification and
# layer-2 diff-content stage predicates are separately ticketed.
#
# Usage:
#   fm-pipeline-dispatch.sh [--state DIR] [--pipeline-dir DIR]
#                           [--stage STAGE] [--no-spawn] [--spawn]
#                           [--harness NAME] [--max N]
# Exit: 0 after a complete pass (actions printed); 2 on usage error.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
PIPELINE_DIR="${FM_PIPELINE_DIR_OVERRIDE:-${FM_HOME}/state/pipeline}"

# shellcheck source=bin/fm-pipeline-lib.sh
. "$SCRIPT_DIR/fm-pipeline-lib.sh"
# shellcheck source=bin/fm-ready-check.sh
. "$SCRIPT_DIR/fm-ready-check.sh"

SPAWN=1
STAGE_FILTER=
HARNESS="${FM_PIPELINE_REVIEW_HARNESS:-}"
MAX=1

while [ "$#" -gt 0 ]; do
  case "$1" in
    --state) STATE=$2; shift 2 ;;
    --pipeline-dir) PIPELINE_DIR=$2; shift 2 ;;
    --stage) STAGE_FILTER=$2; shift 2 ;;
    --no-spawn) SPAWN=0; shift ;;
    --spawn) SPAWN=1; shift ;;
    --harness) HARNESS=$2; shift 2 ;;
    --max) MAX=$2; shift 2 ;;
    -h|--help)
      sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "usage: fm-pipeline-dispatch.sh [--state DIR] [--pipeline-dir DIR] [--stage S] [--no-spawn] [--harness H] [--max N]" >&2
      exit 2
      ;;
  esac
done

fm_pipeline_init "$PIPELINE_DIR"

if [ -z "$HARNESS" ] && [ -f "$CONFIG/crew-harness" ]; then
  HARNESS=$(tr -d '[:space:]' < "$CONFIG/crew-harness" | head -1 || true)
  [ "$HARNESS" = default ] && HARNESS=
fi

_fm_dispatch_stages() {
  if [ -n "$STAGE_FILTER" ]; then
    printf '%s\n' "$STAGE_FILTER"
  else
    # shellcheck disable=SC2086
    printf '%s\n' $FM_PIPELINE_STAGES
  fi
}

dispatched=0

while IFS= read -r stage; do
  [ -n "$stage" ] || continue
  [ "$dispatched" -lt "$MAX" ] || break

  while IFS=' ' read -r task _ready_sha; do
    [ -n "$task" ] || continue
    [ "$dispatched" -lt "$MAX" ] || break 2

    # Skip if this stage already has a prepared brief and active claim.
    claimer=$(fm_pipeline_reviewer_task_id "$task" "$stage")
    if [ -f "$DATA/$claimer/brief.md" ] \
      && [ "$(fm_claim_holder "$PIPELINE_DIR" "$task" 2>/dev/null || true)" = "$claimer" ]; then
      continue
    fi

    if fm_claim_is_active "$PIPELINE_DIR" "$task" 2>/dev/null; then
      continue
    fi

    if ! fm_pipeline_independent "$STATE" "$task" "$claimer" 2>/dev/null; then
      if [ ! -f "$STATE/$task.status" ] \
        || ! grep -q "blocked: pipeline independence" "$STATE/$task.status" 2>/dev/null; then
        echo "blocked: pipeline independence — no durable implementer id or self-review for $task stage $stage" \
          >> "$STATE/$task.status"
      fi
      printf 'dispatch: BLOCKED-INDEPENDENCE %s %s\n' "$task" "$stage"
      continue
    fi

    live=$(fm_pipeline_refresh_pr_head "$STATE" "$task" "$PIPELINE_DIR" 2>/dev/null || true)
    sha=$(fm_ready_field "$PIPELINE_DIR" "$task" sha 2>/dev/null || true)
    [ -n "$live" ] && sha=$live
    if [ -z "$sha" ] || ! fm_pr_head_valid "$sha"; then
      printf 'dispatch: NO-HEAD %s\n' "$task"
      continue
    fi

    if ! fm_claim_acquire "$PIPELINE_DIR" "$task" "$claimer" "$sha" "$stage"; then
      continue
    fi

    brief_out=
    if ! brief_out=$("$SCRIPT_DIR/fm-review-brief.sh" "$task" "$stage" \
      --sha "$sha" --claimer "$claimer" --state "$STATE" \
      --pipeline-dir "$PIPELINE_DIR" \
      --out "$DATA/$claimer/brief.md"); then
      fm_claim_release "$PIPELINE_DIR" "$task" "$claimer" 2>/dev/null || true
      echo "blocked: pipeline brief composition failed for $task stage $stage" \
        >> "$STATE/$task.status"
      printf 'dispatch: BRIEF-FAILED %s %s\n' "$task" "$stage"
      continue
    fi

    {
      echo "kind=scout"
      echo "reviews=$task"
      echo "review_stage=$stage"
      echo "review_sha=$sha"
      echo "implementer=$claimer"
      echo "harness=${HARNESS:-pending}"
    } > "$STATE/$claimer.meta"

    echo "review-dispatched: $stage [by=$claimer] [sha=$sha] [brief=$brief_out]" \
      >> "$STATE/$task.status"

    if [ "$SPAWN" -eq 1 ]; then
      if [ -z "$HARNESS" ]; then
        echo "blocked: pipeline dispatch needs a review harness (set FM_PIPELINE_REVIEW_HARNESS or config/crew-harness) for $task" \
          >> "$STATE/$task.status"
        printf 'dispatch: BLOCKED-HARNESS %s %s claimer=%s brief=%s\n' \
          "$task" "$stage" "$claimer" "$brief_out"
        dispatched=$((dispatched + 1))
        continue
      fi

      proj=$(grep '^project=' "$STATE/$task.meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
      if [ -z "$proj" ] || [ ! -d "$proj" ]; then
        echo "blocked: pipeline dispatch missing project path for $task" \
          >> "$STATE/$task.status"
        printf 'dispatch: BLOCKED-PROJECT %s %s\n' "$task" "$stage"
        dispatched=$((dispatched + 1))
        continue
      fi

      if FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" \
        "$SCRIPT_DIR/fm-spawn.sh" "$claimer" "$proj" --scout --harness "$HARNESS" \
        >/dev/null 2>"$STATE/$claimer.spawn-err"; then
        printf 'dispatch: SPAWNED %s %s claimer=%s sha=%s\n' \
          "$task" "$stage" "$claimer" "$sha"
      else
        err=$(head -c 200 "$STATE/$claimer.spawn-err" 2>/dev/null | tr '\n' ' ' || true)
        echo "blocked: pipeline spawn failed for $claimer on $task: $err" \
          >> "$STATE/$task.status"
        printf 'dispatch: SPAWN-FAILED %s %s claimer=%s\n' "$task" "$stage" "$claimer"
      fi
    else
      printf 'dispatch: PREPARED %s %s claimer=%s sha=%s brief=%s\n' \
        "$task" "$stage" "$claimer" "$sha" "$brief_out"
    fi

    dispatched=$((dispatched + 1))
  done < <(fm_ready_list "$PIPELINE_DIR" "$stage")
done < <(_fm_dispatch_stages)

exit 0
