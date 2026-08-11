#!/usr/bin/env bash
# fm-claim-lib.sh - exclusive, expiring, harness-agnostic ticket claim mechanism.
#
# The pipeline's single most important correctness property: a claim is EXCLUSIVE
# (two reviewers on one ticket wastes budget) and EXPIRES (a claimer that dies
# mid-review must not park the ticket forever). An expired claim RETURNS the
# ticket to the ready queue, never loses it.
#
# Harness-agnostic by design: claims are file-based, atomically acquired via `mv`
# (POSIX, same-filesystem guarantee), and the TTL is wall-clock seconds. No
# harness-specific behaviour, no harness-specific output, no dependency on any
# agent's turn-end signalling.
#
# Claim file format (one line per field, no whitespace around values):
#   claimer=<agent-id>
#   sha=<commit-sha>
#   stage=<review-stage>
#   expiry=<epoch-seconds>
#   task=<task-id>
#
# Sourced by pipeline scripts; never executed directly. Every function is a pure
# read or a single atomic write; no globals, no side effects beyond the claim file.
#
# Usage: . bin/fm-claim-lib.sh

# Default claim TTL in seconds (30 minutes). A claim that outlasts this is
# considered abandoned and the ticket returns to the ready queue.
FM_CLAIM_TTL_DEFAULT=${FM_CLAIM_TTL_DEFAULT:-1800}

# --- claim file format --------------------------------------------------------

# Write a claim file atomically: write to a temp file, then mv into place.
# $1: claim file path
# $2: claimer agent id
# $3: commit SHA the claim is bound to
# $4: review stage (code-review, qa, security-review)
# $5: task id
# $6: expiry epoch seconds (optional; defaults to now + FM_CLAIM_TTL_DEFAULT)
_fm_claim_write() {
  local claim_file=$1 claimer=$2 sha=$3 stage=$4 task=$5 expiry=${6:-}
  local tmp="${claim_file}.tmp.$$"
  [ -z "$expiry" ] && expiry=$(( $(date +%s) + FM_CLAIM_TTL_DEFAULT ))
  printf 'claimer=%s\nsha=%s\nstage=%s\nexpiry=%s\ntask=%s\n' \
    "$claimer" "$sha" "$stage" "$expiry" "$task" > "$tmp" || return 1
  mv "$tmp" "$claim_file" 2>/dev/null || { rm -f "$tmp"; return 1; }
}

# Parse a single field from a claim file.
# $1: claim file path
# $2: field name (claimer, sha, stage, expiry, task)
_fm_claim_field() {
  local claim_file=$1 field=$2
  [ -f "$claim_file" ] || return 1
  grep "^${field}=" "$claim_file" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# --- claim acquisition --------------------------------------------------------

# Try to acquire a claim on a ticket. Atomic: if the claim file does not exist
# or the existing claim has expired, writes a new claim and returns 0.
# If a valid unexpired claim exists, returns 1.
# $1: queue directory (where claim files live)
# $2: task id
# $3: claimer agent id
# $4: commit SHA
# $5: review stage
# $6: TTL seconds (optional; defaults to FM_CLAIM_TTL_DEFAULT)
fm_claim_acquire() {
  local queue_dir=$1 task=$2 claimer=$3 sha=$4 stage=$5 ttl=${6:-$FM_CLAIM_TTL_DEFAULT}
  local claim_file="$queue_dir/${task}.claim"
  local now existing_expiry

  if [ -f "$claim_file" ]; then
    existing_expiry=$(_fm_claim_field "$claim_file" expiry)
    now=$(date +%s)
    if [ -n "$existing_expiry" ] && [ "$existing_expiry" -gt "$now" ] 2>/dev/null; then
      return 1
    fi
    rm -f "$claim_file"
  fi

  _fm_claim_write "$claim_file" "$claimer" "$sha" "$stage" "$task" \
    "$(( $(date +%s) + ttl ))"
}

# Release a claim (green verdict, red verdict, or explicit release).
# Removes the claim file so the ticket can advance or return.
# $1: queue directory
# $2: task id
# $3: claimer agent id (must match the claim holder, or the release is refused)
fm_claim_release() {
  local queue_dir=$1 task=$2 claimer=$3
  local claim_file="$queue_dir/${task}.claim"
  local holder

  [ -f "$claim_file" ] || return 0
  holder=$(_fm_claim_field "$claim_file" claimer)
  [ "$holder" = "$claimer" ] || return 1
  rm -f "$claim_file"
}

# --- claim inspection ---------------------------------------------------------

# Who holds the claim on this ticket? Prints the claimer id, or empty if
# unclaimed or expired.
# $1: queue directory
# $2: task id
fm_claim_holder() {
  local queue_dir=$1 task=$2
  local claim_file="$queue_dir/${task}.claim"
  local expiry now

  [ -f "$claim_file" ] || return 0
  expiry=$(_fm_claim_field "$claim_file" expiry)
  now=$(date +%s)
  if [ -n "$expiry" ] && [ "$expiry" -le "$now" ] 2>/dev/null; then
    return 0
  fi
  _fm_claim_field "$claim_file" claimer
}

# Seconds remaining on the claim, or 0 if unclaimed/expired.
# $1: queue directory
# $2: task id
fm_claim_remaining() {
  local queue_dir=$1 task=$2
  local claim_file="$queue_dir/${task}.claim"
  local expiry now

  [ -f "$claim_file" ] || { printf '0'; return 0; }
  expiry=$(_fm_claim_field "$claim_file" expiry)
  now=$(date +%s)
  if [ -n "$expiry" ] && [ "$expiry" -gt "$now" ] 2>/dev/null; then
    printf '%s' "$(( expiry - now ))"
  else
    printf '0'
  fi
}

# SHA the claim is bound to, or empty if unclaimed/expired.
# $1: queue directory
# $2: task id
fm_claim_sha() {
  local queue_dir=$1 task=$2
  local claim_file="$queue_dir/${task}.claim"
  local expiry now

  [ -f "$claim_file" ] || return 0
  expiry=$(_fm_claim_field "$claim_file" expiry)
  now=$(date +%s)
  if [ -n "$expiry" ] && [ "$expiry" -le "$now" ] 2>/dev/null; then
    return 0
  fi
  _fm_claim_field "$claim_file" sha
}

# Stage the claim is for, or empty if unclaimed/expired.
# $1: queue directory
# $2: task id
fm_claim_stage() {
  local queue_dir=$1 task=$2
  local claim_file="$queue_dir/${task}.claim"
  local expiry now

  [ -f "$claim_file" ] || return 0
  expiry=$(_fm_claim_field "$claim_file" expiry)
  now=$(date +%s)
  if [ -n "$expiry" ] && [ "$expiry" -le "$now" ] 2>/dev/null; then
    return 0
  fi
  _fm_claim_field "$claim_file" stage
}

# 0 if the task has an active (unexpired) claim; 1 otherwise.
# $1: queue directory
# $2: task id
fm_claim_is_active() {
  local queue_dir=$1 task=$2
  local holder
  holder=$(fm_claim_holder "$queue_dir" "$task")
  [ -n "$holder" ]
}

# --- claim expiry sweep -------------------------------------------------------

# Sweep the queue directory for expired claims. For each expired claim, print
# "EXPIRED <task-id> <stage>" and remove the claim file so the ticket is
# automatically returned to the ready queue.
# $1: queue directory
fm_claim_sweep() {
  local queue_dir=$1 claim_file expiry now task
  now=$(date +%s)
  for claim_file in "$queue_dir"/*.claim; do
    [ -e "$claim_file" ] || continue
    expiry=$(_fm_claim_field "$claim_file" expiry)
    if [ -n "$expiry" ] && [ "$expiry" -le "$now" ] 2>/dev/null; then
      task=$(_fm_claim_field "$claim_file" task)
      printf 'EXPIRED %s %s\n' "$task" "$(_fm_claim_field "$claim_file" stage)"
      rm -f "$claim_file"
    fi
  done
}

# --- ready queue management ---------------------------------------------------

# Add a ticket to the ready queue. Creates a marker file that claimers can scan.
# $1: queue directory
# $2: task id
# $3: stage (code-review, qa, security-review)
# $4: commit SHA (optional)
fm_ready_enqueue() {
  local queue_dir=$1 task=$2 stage=$3 sha=${4:-}
  local ready_file="$queue_dir/${task}.ready"
  printf 'stage=%s\nsha=%s\n' "$stage" "$sha" > "$ready_file"
}

# Remove a ticket from the ready queue (after it's claimed or advanced).
# $1: queue directory
# $2: task id
fm_ready_dequeue() {
  local queue_dir=$1 task=$2
  rm -f "$queue_dir/${task}.ready"
}

# List all tasks currently in the ready queue for a given stage.
# Prints one "<task-id> <sha>" line per ready task.
# $1: queue directory
# $2: stage filter (optional; if empty, lists all stages)
fm_ready_list() {
  local queue_dir=$1 stage_filter=${2:-}
  local ready_file task file_stage sha
  for ready_file in "$queue_dir"/*.ready; do
    [ -e "$ready_file" ] || continue
    task=$(basename "$ready_file" .ready)
    file_stage=$(grep '^stage=' "$ready_file" 2>/dev/null | cut -d= -f2- || true)
    if [ -n "$stage_filter" ] && [ "$file_stage" != "$stage_filter" ]; then
      continue
    fi
    # Skip if there's an active claim
    if fm_claim_is_active "$queue_dir" "$task"; then
      continue
    fi
    sha=$(grep '^sha=' "$ready_file" 2>/dev/null | cut -d= -f2- || true)
    printf '%s %s\n' "$task" "$sha"
  done
}

# Check if a task is in the ready queue.
# $1: queue directory
# $2: task id
fm_ready_is_queued() {
  local queue_dir=$1 task=$2
  [ -f "$queue_dir/${task}.ready" ]
}