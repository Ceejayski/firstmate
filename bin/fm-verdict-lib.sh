#!/usr/bin/env bash
# fm-verdict-lib.sh - SHA-bound, stage-aware verdict contract for the pipeline.
#
# A verdict is a status-line append that records:
#   - The outcome (green, red, cannot-verify)
#   - The exact commit SHA it was given for
#   - The review stage (code-review, qa, security-review)
#   - The reviewer agent id
#   - Optional findings summary
#
# The SHA binding is the load-bearing correctness property: a verdict on SHA A
# must not be used to merge SHA B. If the PR has moved, the verdict is stale.
#
# Verdict format:
#   verdict: green|red|cannot-verify [sha=<sha>] [stage=<stage>] [by=<agent>] [findings=<N>]
#
# This is a status-line append, so it flows through the existing wake-queue
# machinery and wakes firstmate when the pipeline reaches a terminal state.
#
# Harness-agnostic: a verdict is just a formatted string. The merge agent
# verifies the SHA against the current PR head independently.
#
# Usage: . bin/fm-verdict-lib.sh

# --- verdict construction -----------------------------------------------------

# Build a verdict status line.
# $1: outcome (green, red, cannot-verify)
# $2: commit SHA
# $3: review stage (code-review, qa, security-review)
# $4: reviewer agent id
# $5: findings count (optional)
_fm_verdict_build() {
  local outcome=$1 sha=$2 stage=$3 reviewer=$4 findings=${5:-}
  local line="verdict: ${outcome} [sha=${sha}] [stage=${stage}] [by=${reviewer}]"
  [ -n "$findings" ] && line="${line} [findings=${findings}]"
  printf '%s' "$line"
}

# --- verdict parsing ----------------------------------------------------------

# Extract the outcome from a verdict line.
# $1: verdict line
fm_verdict_outcome() {
  local line=$1
  case "$line" in
    *verdict:\ green*)   printf 'green' ;;
    *verdict:\ red*)     printf 'red' ;;
    *verdict:\ cannot-verify*) printf 'cannot-verify' ;;
    *) printf 'unknown' ;;
  esac
}

# Extract a field from a verdict line's [key=value] tokens.
# $1: verdict line
# $2: key name (sha, stage, by, findings)
fm_verdict_field() {
  local line=$1 key=$2
  printf '%s' "$line" | grep -o "\[${key}=[^]]*\]" | head -1 | sed "s/\[${key}=//;s/\]//"
}

# Extract the SHA from a verdict line.
fm_verdict_sha() { fm_verdict_field "$1" sha; }

# Extract the stage from a verdict line.
fm_verdict_stage() { fm_verdict_field "$1" stage; }

# Extract the reviewer from a verdict line.
fm_verdict_reviewer() { fm_verdict_field "$1" by; }

# Extract the findings count from a verdict line.
fm_verdict_findings() { fm_verdict_field "$1" findings; }

# --- verdict validation -------------------------------------------------------

# 0 if the verdict line is well-formed (has all required fields).
# $1: verdict line
fm_verdict_is_valid() {
  local line=$1 outcome sha stage reviewer
  outcome=$(fm_verdict_outcome "$line")
  [ "$outcome" != unknown ] || return 1
  sha=$(fm_verdict_sha "$line")
  [ -n "$sha" ] || return 1
  stage=$(fm_verdict_stage "$line")
  [ -n "$stage" ] || return 1
  reviewer=$(fm_verdict_reviewer "$line")
  [ -n "$reviewer" ] || return 1
  return 0
}

# 0 if the verdict is green (the ticket can advance to the next stage).
# $1: verdict line
fm_verdict_is_green() {
  [ "$(fm_verdict_outcome "$1")" = green ]
}

# 0 if the verdict is red (the ticket must return to the implementer).
# $1: verdict line
fm_verdict_is_red() {
  [ "$(fm_verdict_outcome "$1")" = red ]
}

# 0 if the verdict is cannot-verify (escalation needed).
# $1: verdict line
fm_verdict_is_cannot_verify() {
  [ "$(fm_verdict_outcome "$1")" = cannot-verify ]
}

# --- SHA binding verification -------------------------------------------------

# 0 if the verdict's SHA matches the given current SHA. This is the guard that
# prevents merging a PR that has moved since the verdict was given.
# $1: verdict line
# $2: current commit SHA
fm_verdict_sha_matches() {
  local line=$1 current_sha=$2 verdict_sha
  verdict_sha=$(fm_verdict_sha "$line")
  [ "$verdict_sha" = "$current_sha" ]
}

# --- verdict appending --------------------------------------------------------

# Append a verdict to a task's status file, waking firstmate.
# $1: state directory
# $2: task id
# $3: outcome (green, red, cannot-verify)
# $4: commit SHA
# $5: review stage
# $6: reviewer agent id
# $7: findings count (optional)
fm_verdict_append() {
  local state=$1 task=$2 outcome=$3 sha=$4 stage=$5 reviewer=$6 findings=${7:-}
  local status="$state/$task.status"
  local line
  line=$(_fm_verdict_build "$outcome" "$sha" "$stage" "$reviewer" "$findings")
  printf '%s\n' "$line" >> "$status"
}

# --- pipeline stage progression -----------------------------------------------

# Given a stage, return the next stage in the pipeline, or "merge" if it's the
# last review stage, or empty if the stage is unknown.
# $1: current stage
fm_verdict_next_stage() {
  local current=$1
  case "$current" in
    code-review)     printf 'qa' ;;
    qa)              printf 'security-review' ;;
    security-review) printf 'merge' ;;
    *)               return 1 ;;
  esac
}

# Given a stage, return the previous stage, or empty if it's the first.
# $1: current stage
fm_verdict_prev_stage() {
  local current=$1
  case "$current" in
    qa)              printf 'code-review' ;;
    security-review) printf 'qa' ;;
    merge)           printf 'security-review' ;;
    *)              return 1 ;;
  esac
}

# 0 if the stage is a valid pipeline stage.
# $1: stage name
fm_verdict_is_valid_stage() {
  local stage=$1
  case "$stage" in
    code-review|qa|security-review|merge) return 0 ;;
    *) return 1 ;;
  esac
}