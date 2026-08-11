#!/usr/bin/env bash
# tests/fm-pipeline-lib.test.sh - pipeline stage tracking and transition tests.
#
# The pipeline ties claims, verdicts, and readiness into one lifecycle.
# These tests prove:
#   1. Stage transitions: green → next stage, red → back to implementer
#   2. Independence: implementer and reviewer must be different agents
#   3. Claim-next: picks the next available ticket at a stage
#   4. Sweep: expired claims are returned to the queue
#   5. Current stage: correctly reads the pipeline position from status
#   6. Harness-agnostic: all operations are pure file/status based
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Set FM_HOME before sourcing the pipeline lib so its default resolves to our
# temp dir, not $HOME/.firstmate. Must be done in the parent shell, not a
# subshell, so the export survives.
export FM_HOME
FM_HOME=$(fm_test_tmproot fm-pipeline-lib-tests)

# shellcheck source=bin/fm-pipeline-lib.sh
. "$ROOT/bin/fm-pipeline-lib.sh"

# One-time setup
Q="$FM_HOME/pipeline"
STATE="$FM_HOME/state"
mkdir -p "$Q" "$STATE"

# --- test helpers ------------------------------------------------------------

# Write a fresh empty status file for a task.
fresh_status() {
  local task=$1
  : > "$STATE/$task.status"
}

# --- stage transitions -------------------------------------------------------

test_advance_code_review_to_qa() {
  fresh_status "task-1"
  fm_pipeline_advance "$Q" "task-1" "code-review" "abc123"
  [ -f "$Q/task-1.ready" ] || fail "ready file should exist"
  grep -q "stage=qa" "$Q/task-1.ready" || fail "ready file should have stage=qa"
  grep -q "ready-for-review: qa" "$STATE/task-1.status" || fail "status should have ready-for-review: qa"
  pass "advance code-review → qa"
}

test_advance_qa_to_security_review() {
  fresh_status "task-2"
  fm_pipeline_advance "$Q" "task-2" "qa" "abc123"
  grep -q "stage=security-review" "$Q/task-2.ready" || fail "ready file should have stage=security-review"
  pass "advance qa → security-review"
}

test_advance_security_review_to_merge() {
  fresh_status "task-3"
  fm_pipeline_advance "$Q" "task-3" "security-review" "abc123"
  [ ! -f "$Q/task-3.ready" ] || fail "no ready file should exist for merge stage"
  grep -q "ready-for-merge" "$STATE/task-3.status" || fail "status should have ready-for-merge"
  pass "advance security-review → merge"
}

test_return_to_implementer() {
  fresh_status "task-4"
  fm_pipeline_return "$Q" "task-4" "code-review" "3 findings"
  grep -q "returned: code-review returned red" "$STATE/task-4.status" || fail "status should have returned:"
  grep -q "findings=3" "$STATE/task-4.status" || fail "status should have findings count"
  pass "return to implementer after red verdict"
}

# --- independence enforcement ------------------------------------------------

test_independent_reviewer_passes() {
  printf 'harness=qwen\nmodel=qwen3.6-flash\n' > "$STATE/task-5.meta"
  fm_pipeline_independent "$STATE" "task-5" "claude" || fail "different harness should be independent"
  pass "independent reviewer passes (different harness)"
}

test_same_harness_reviewer_fails() {
  printf 'harness=qwen\nmodel=qwen3.6-flash\n' > "$STATE/task-6.meta"
  fm_pipeline_independent "$STATE" "task-6" "qwen" && fail "same harness should fail independence"
  pass "same harness reviewer fails independence"
}

# --- claim next --------------------------------------------------------------

test_claim_next_picks_available() {
  fm_ready_enqueue "$Q" "task-7" "code-review" "abc123"
  fm_ready_enqueue "$Q" "task-8" "code-review" "def456"
  local result
  result=$(fm_pipeline_claim_next "$Q" "code-review" "reviewer-alpha")
  [ -n "$result" ] || fail "should have claimed a ticket"
  printf '%s' "$result" | grep -q "task-" || fail "should return task-id and sha"
  local count
  count=$(fm_ready_list "$Q" "code-review" | grep -c '^' 2>/dev/null || printf '0')
  [ "$count" -eq 1 ] || fail "one ticket should remain, got $count"
  pass "claim_next picks one available ticket"
}

test_claim_next_skips_claimed() {
  fm_ready_enqueue "$Q" "task-9" "code-review" "abc123"
  fm_ready_enqueue "$Q" "task-10" "code-review" "def456"
  fm_claim_acquire "$Q" "task-9" "other-reviewer" "abc123" "code-review" 60
  local result
  result=$(fm_pipeline_claim_next "$Q" "code-review" "reviewer-alpha")
  printf '%s' "$result" | grep -q "task-10" || fail "should pick task-10 (task-9 claimed)"
  pass "claim_next skips claimed tickets"
}

# --- pipeline sweep ----------------------------------------------------------

test_pipeline_sweep_expired() {
  fm_claim_acquire "$Q" "task-11" "reviewer-alpha" "abc123" "code-review" 1
  sleep 2
  fm_pipeline_sweep "$Q"
  [ ! -f "$Q/task-11.claim" ] || fail "expired claim should be removed after sweep"
  pass "pipeline_sweep removes expired claims"
}

# --- current stage -----------------------------------------------------------

test_current_stage_from_status() {
  fresh_status "task-12"
  echo "ready-for-review: code-review [sha=abc123]" > "$STATE/task-12.status"
  local stage
  stage=$(fm_pipeline_current_stage "$STATE" "task-12")
  [ "$stage" = "code-review" ] || fail "expected code-review, got '$stage'"
  pass "current_stage reads ready-for-review"
}

test_current_stage_from_verdict() {
  fresh_status "task-13"
  echo "verdict: green [sha=abc123] [stage=qa] [by=reviewer-alpha]" > "$STATE/task-13.status"
  local stage
  stage=$(fm_pipeline_current_stage "$STATE" "task-13")
  [ "$stage" = "qa" ] || fail "expected qa, got '$stage'"
  pass "current_stage reads verdict stage"
}

test_current_stage_ready_for_merge() {
  fresh_status "task-14"
  echo "ready-for-merge: all review stages passed" > "$STATE/task-14.status"
  local stage
  stage=$(fm_pipeline_current_stage "$STATE" "task-14")
  [ "$stage" = "merge" ] || fail "expected merge, got '$stage'"
  pass "current_stage detects ready-for-merge"
}

# --- run all tests -----------------------------------------------------------

test_advance_code_review_to_qa
test_advance_qa_to_security_review
test_advance_security_review_to_merge
test_return_to_implementer
test_independent_reviewer_passes
test_same_harness_reviewer_fails
test_claim_next_picks_available
test_claim_next_skips_claimed
test_pipeline_sweep_expired
test_current_stage_from_status
test_current_stage_from_verdict
test_current_stage_ready_for_merge

printf '\n1..%d\n' 12