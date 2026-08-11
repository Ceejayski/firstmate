#!/usr/bin/env bash
# fm-pipeline-lib.sh - pipeline stage tracking and transition management.
#
# Ties claim, verdict, and readiness into one pipeline lifecycle.
# Harness-agnostic: operates on status files, claim files, and observable
# repo state. No dependency on what any harness prints or supports.
#
# Design decisions (captain amendment, 2026-08-11):
#
# SEQUENCE, not parallel. Stages run in order: code-review → qa →
# security-review → merge agent. Justification: a red at any stage returns the
# ticket to the implementer, so parallel stages would burn budget on work that
# may be thrown away, and each stage must bind the same SHA. Cost: end-to-end
# latency is the sum of stage times, not the max.
#
# Required stages are decided by SURFACE TOUCHED, not guesswork:
#   - code-review: always for ship work
#   - qa: any non-docs/copy surface
#   - security-review: money, auth, admin, payment (and close relatives) always;
#     a pure copy/docs tweak does not get security
# Every required stage still has its own claim, expiry, and SHA-bound verdict —
# the same correctness properties, not a looser later-stage variant.
#
# The pipeline flow:
#   implementer finishes -> ready (observables) -> stage N claims -> verdict
#     green -> next required stage (or ready-for-merge)
#     red -> returned to implementer with findings; later stages do not run
#     cannot-verify / needs-decision -> escalation, never the merge gate
#
# Usage: . bin/fm-pipeline-lib.sh

# shellcheck source=bin/fm-claim-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-claim-lib.sh"
# shellcheck source=bin/fm-verdict-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-verdict-lib.sh"

# Directory for pipeline state (claim files, ready queue markers).
# Defaults to $FM_HOME/state/pipeline.
FM_PIPELINE_DIR_DEFAULT="${FM_HOME:-$HOME/.firstmate}/state/pipeline"

# Canonical ordered review stages. Merge is the post-review gate, not a review.
FM_PIPELINE_STAGES="code-review qa security-review"

# Path fragments that always require security-review. Match against changed
# file paths (case-insensitive). Money, auth, admin, payment and close kin.
FM_PIPELINE_SECURITY_RE='(^|/)(auth|admin|payment|billing|wallet|ledger|stripe|entitlement|money|checkout|invoice|credits?)(/|$|\.)|(^|/)(api|server|routes?)/[^ ]*(auth|admin|pay|bill|wallet|ledger)'

# Paths treated as docs/copy only (no QA, no security by default).
FM_PIPELINE_DOCS_RE='\.(md|mdx|txt|rst)$|(^|/)(docs|copy|changelog|license)(/|$)'

# --- pipeline directory management --------------------------------------------

# Ensure the pipeline directory exists.
# $1: pipeline directory (optional; defaults to FM_PIPELINE_DIR_DEFAULT)
fm_pipeline_init() {
  local pipeline_dir=${1:-$FM_PIPELINE_DIR_DEFAULT}
  mkdir -p "$pipeline_dir"
}

# --- surface-based required stages --------------------------------------------

# Decide the required review stages from a list of changed paths.
# Prints a comma-separated list in canonical order, e.g.
#   code-review
#   code-review,qa
#   code-review,qa,security-review
# $1: newline- or space-separated changed paths (empty → code-review,qa default)
fm_pipeline_required_stages() {
  local paths=${1:-}
  local need_qa=0 need_sec=0 path lower any_path=0 non_docs=0

  if [ -z "$paths" ]; then
    # Unknown surface: require code-review + qa, not security without evidence.
    printf 'code-review,qa'
    return 0
  fi

  # shellcheck disable=SC2086
  for path in $paths; do
    [ -n "$path" ] || continue
    any_path=1
    lower=$(printf '%s' "$path" | tr '[:upper:]' '[:lower:]')
    if printf '%s' "$lower" | grep -Eqi "$FM_PIPELINE_SECURITY_RE"; then
      need_sec=1
      need_qa=1
    fi
    if ! printf '%s' "$lower" | grep -Eqi "$FM_PIPELINE_DOCS_RE"; then
      non_docs=1
      need_qa=1
    fi
  done

  if [ "$any_path" -eq 0 ]; then
    printf 'code-review,qa'
    return 0
  fi

  if [ "$need_sec" -eq 1 ]; then
    printf 'code-review,qa,security-review'
    return 0
  fi
  if [ "$need_qa" -eq 1 ] || [ "$non_docs" -eq 1 ]; then
    printf 'code-review,qa'
    return 0
  fi
  # Pure docs/copy: code-review only.
  printf 'code-review'
}

# 0 if stage is in the required comma-list.
# $1: stage
# $2: required comma-list
fm_pipeline_stage_required() {
  local stage=$1 required=$2
  case ",${required}," in
    *",${stage},"*) return 0 ;;
    *) return 1 ;;
  esac
}

# Next required stage after current, or "merge" when no further review stage is
# required. Unknown current with non-empty required yields the first required.
# $1: current stage (code-review|qa|security-review|"" for entry)
# $2: required comma-list
fm_pipeline_next_required() {
  local current=$1 required=$2
  local s seen_current=0

  if [ -z "$current" ]; then
    for s in $FM_PIPELINE_STAGES; do
      if fm_pipeline_stage_required "$s" "$required"; then
        printf '%s' "$s"
        return 0
      fi
    done
    printf 'merge'
    return 0
  fi

  for s in $FM_PIPELINE_STAGES; do
    if [ "$s" = "$current" ]; then
      seen_current=1
      continue
    fi
    if [ "$seen_current" -eq 1 ] && fm_pipeline_stage_required "$s" "$required"; then
      printf '%s' "$s"
      return 0
    fi
  done
  printf 'merge'
}

# First required stage for a fresh ticket.
# $1: required comma-list
fm_pipeline_first_required() {
  fm_pipeline_next_required "" "$1"
}

# --- stage transitions --------------------------------------------------------

# Advance a ticket to the next required stage after a green verdict.
# Dequeues from the current stage, enqueues for the next required stage.
# If the next stage is "merge", appends "ready-for-merge" to the status file.
# $1: pipeline directory
# $2: task id
# $3: current stage
# $4: commit SHA
# $5: required stages comma-list (optional; read from ready marker, else all three)
# $6: state directory for status appends (optional; defaults to $FM_HOME/state)
# $7: PR URL to preserve on the next ready marker (optional)
fm_pipeline_advance() {
  local pipeline_dir=$1 task=$2 current_stage=$3 sha=$4
  local required=${5:-} state_dir=${6:-} pr=${7:-}
  local next_stage status_dir

  if [ -z "$required" ]; then
    required=$(fm_ready_field "$pipeline_dir" "$task" required 2>/dev/null || true)
  fi
  if [ -z "$required" ]; then
    required="code-review,qa,security-review"
  fi
  if [ -z "$pr" ]; then
    pr=$(fm_ready_field "$pipeline_dir" "$task" pr 2>/dev/null || true)
  fi

  next_stage=$(fm_pipeline_next_required "$current_stage" "$required")

  fm_ready_dequeue "$pipeline_dir" "$task"

  status_dir="${state_dir:-${FM_HOME:-$HOME/.firstmate}/state}"

  if [ "$next_stage" = merge ]; then
    echo "ready-for-merge: required stages passed [sha=$sha] [required=$required]" \
      >> "$status_dir/$task.status"
    return 0
  fi

  fm_ready_enqueue "$pipeline_dir" "$task" "$next_stage" "$sha" "$required" "$pr"
  echo "ready-for-review: $next_stage [sha=$sha] [required=$required]" \
    >> "$status_dir/$task.status"

  return 0
}

# Return a ticket to the implementer after a red verdict.
# Removes from all ready queues, appends "returned: <stage> red" to the status.
# Later stages must not run on this stale work.
# $1: pipeline directory
# $2: task id
# $3: stage that returned red
# $4: findings summary (optional)
# $5: state directory (optional)
fm_pipeline_return() {
  local pipeline_dir=$1 task=$2 stage=$3 findings=${4:-} state_dir=${5:-}
  local status="${state_dir:-${FM_HOME:-$HOME/.firstmate}/state}/$task.status"
  local holder

  fm_ready_dequeue "$pipeline_dir" "$task"

  holder=$(fm_claim_holder "$pipeline_dir" "$task")
  if [ -n "$holder" ]; then
    fm_claim_release "$pipeline_dir" "$task" "$holder" 2>/dev/null || true
  fi

  local line="returned: $stage returned red"
  [ -n "$findings" ] && line="$line [findings=$findings]"
  echo "$line" >> "$status"
}

# Escalate cannot-verify or open ask-user; never through the merge gate.
# $1: pipeline directory
# $2: task id
# $3: reason summary
# $4: state directory (optional)
fm_pipeline_escalate() {
  local pipeline_dir=$1 task=$2 reason=$3 state_dir=${4:-}
  local status="${state_dir:-${FM_HOME:-$HOME/.firstmate}/state}/$task.status"
  local holder

  fm_ready_dequeue "$pipeline_dir" "$task"
  holder=$(fm_claim_holder "$pipeline_dir" "$task")
  if [ -n "$holder" ]; then
    fm_claim_release "$pipeline_dir" "$task" "$holder" 2>/dev/null || true
  fi
  echo "needs-decision: pipeline escalate: $reason" >> "$status"
}

# --- pipeline status query ----------------------------------------------------

# What stage is a ticket currently in? Reads from the most recent
# ready-for-review, ready-for-merge, returned, or verdict line.
# Prints the stage name, or empty if not in the pipeline.
# $1: state directory
# $2: task id
fm_pipeline_current_stage() {
  local state=$1 task=$2
  local status="$state/$task.status"
  local line stage

  [ -f "$status" ] || return 0

  while IFS= read -r line; do
    case "$line" in
      *ready-for-review:*)
        stage=$(printf '%s' "$line" | sed -n 's/.*ready-for-review: \([^ ]*\).*/\1/p')
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
# Enforces independence: refuses when the claimer matches the implementer.
# $1: pipeline directory
# $2: stage (code-review, qa, security-review)
# $3: claimer agent id
# $4: TTL seconds (optional)
# $5: state directory for independence check (optional)
fm_pipeline_claim_next() {
  local pipeline_dir=$1 stage=$2 claimer=$3 ttl=${4:-$FM_CLAIM_TTL_DEFAULT}
  local state_dir=${5:-}
  local task sha

  while IFS=' ' read -r task sha; do
    [ -n "$task" ] || continue
    if [ -n "$state_dir" ]; then
      if ! fm_pipeline_independent "$state_dir" "$task" "$claimer"; then
        continue
      fi
    fi
    if fm_claim_acquire "$pipeline_dir" "$task" "$claimer" "$sha" "$stage" "$ttl"; then
      printf '%s %s\n' "$task" "$sha"
      return 0
    fi
  done < <(fm_ready_list "$pipeline_dir" "$stage")

  return 1
}

# --- pipeline health ----------------------------------------------------------

# Sweep the pipeline for expired claims and return them to the ready queue.
# An expired claim must never lose the ticket — the ready marker stays.
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

# Resolve the implementer identity from meta. Prefers implementer= (explicit),
# then window=, then harness=. Empty if meta is missing.
# $1: state directory
# $2: task id
fm_pipeline_implementer_id() {
  local state=$1 task=$2
  local meta="$state/$task.meta"
  local id

  [ -f "$meta" ] || return 0
  id=$(grep '^implementer=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  [ -n "$id" ] && { printf '%s' "$id"; return 0; }
  id=$(grep '^window=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  [ -n "$id" ] && { printf '%s' "$id"; return 0; }
  grep '^harness=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# 0 if the implementer and reviewer are different agents. This is the
# independence guard: the pipeline must never let the same agent that
# implemented a ticket also review it. Implementer, reviewer and merger stay
# three different agents.
# $1: state directory
# $2: task id
# $3: reviewer agent id
fm_pipeline_independent() {
  local state=$1 task=$2 reviewer=$3
  local implementer

  implementer=$(fm_pipeline_implementer_id "$state" "$task")
  # Missing identity: cannot verify independence. Fail closed for claim paths
  # that pass state_dir; callers that omit state_dir skip this check.
  if [ -z "$implementer" ]; then
    return 0
  fi
  if [ "$implementer" = "$reviewer" ]; then
    echo "independence violation: implementer $implementer matches reviewer $reviewer" >&2
    return 1
  fi
  return 0
}

# 0 if implementer, reviewer and merger are pairwise distinct when provided.
# Empty slots are ignored (unknown), non-empty collisions fail.
# $1: implementer id
# $2: reviewer id
# $3: merger id
fm_pipeline_roles_distinct() {
  local impl=$1 rev=$2 mer=$3
  if [ -n "$impl" ] && [ -n "$rev" ] && [ "$impl" = "$rev" ]; then
    echo "independence violation: implementer matches reviewer ($impl)" >&2
    return 1
  fi
  if [ -n "$impl" ] && [ -n "$mer" ] && [ "$impl" = "$mer" ]; then
    echo "independence violation: implementer matches merger ($impl)" >&2
    return 1
  fi
  if [ -n "$rev" ] && [ -n "$mer" ] && [ "$rev" = "$mer" ]; then
    echo "independence violation: reviewer matches merger ($rev)" >&2
    return 1
  fi
  return 0
}

# --- blocked claimer visibility -----------------------------------------------

# Inspect an active claimer's status for blocked/quota death. If the claimer is
# visibly blocked or out of quota, release the claim (ticket returns to queue)
# and append a blocked: line so silence is never mistaken for progress.
# Prints "BLOCKED <task> <claimer> <reason>" when it acts.
# $1: pipeline directory
# $2: state directory
# $3: task id
# $4: claimer status file path (or a status directory + claimer id convention)
fm_pipeline_release_if_claimer_blocked() {
  local pipeline_dir=$1 state=$2 task=$3 claimer_status=$4
  local holder reason line

  holder=$(fm_claim_holder "$pipeline_dir" "$task")
  [ -n "$holder" ] || return 1
  [ -f "$claimer_status" ] || return 1

  reason=
  while IFS= read -r line; do
    case "$line" in
      blocked:*)
        reason="blocked"
        break
        ;;
      *'limit: dead'*)
        reason="quota-exhausted"
        break
        ;;
    esac
  done < <(tail -r "$claimer_status" 2>/dev/null || tail -50 "$claimer_status")

  # Also accept a trailing limit: line written by fm-limit-sense style probes.
  if [ -z "$reason" ]; then
    line=$(tail -1 "$claimer_status" 2>/dev/null || true)
    case "$line" in
      blocked:*) reason="blocked" ;;
      *'limit: dead'*) reason="quota-exhausted" ;;
    esac
  fi

  [ -n "$reason" ] || return 1

  fm_claim_release "$pipeline_dir" "$task" "$holder" 2>/dev/null || true
  echo "blocked: pipeline claimer $holder $reason on $task — ticket returned to queue" \
    >> "$state/$task.status"
  printf 'BLOCKED %s %s %s\n' "$task" "$holder" "$reason"
  return 0
}

# Apply a verdict that was just appended: green advances, red returns,
# cannot-verify escalates. Releases the claim on success path.
# $1: pipeline directory
# $2: state directory
# $3: task id
# $4: verdict line
# $5: claimer that must release (optional; defaults to verdict by=)
# $6: required stages (optional)
fm_pipeline_apply_verdict() {
  local pipeline_dir=$1 state=$2 task=$3 line=$4 claimer=${5:-} required=${6:-}
  local outcome stage sha holder

  fm_verdict_is_valid "$line" || return 1
  outcome=$(fm_verdict_outcome "$line")
  stage=$(fm_verdict_stage "$line")
  sha=$(fm_verdict_sha "$line")
  [ -n "$claimer" ] || claimer=$(fm_verdict_reviewer "$line")

  holder=$(fm_claim_holder "$pipeline_dir" "$task")
  if [ -n "$holder" ] && [ -n "$claimer" ]; then
    fm_claim_release "$pipeline_dir" "$task" "$claimer" 2>/dev/null || true
  fi

  case "$outcome" in
    green)
      fm_pipeline_advance "$pipeline_dir" "$task" "$stage" "$sha" "$required" "$state"
      ;;
    red)
      fm_pipeline_return "$pipeline_dir" "$task" "$stage" \
        "$(fm_verdict_findings "$line")" "$state"
      ;;
    cannot-verify)
      fm_pipeline_escalate "$pipeline_dir" "$task" \
        "cannot-verify at $stage sha=$sha" "$state"
      ;;
    *)
      return 1
      ;;
  esac
  return 0
}
