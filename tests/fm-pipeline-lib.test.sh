#!/usr/bin/env bash
# tests/fm-pipeline-lib.test.sh - pipeline stage tracking and transition tests.
#
# The pipeline ties claims, verdicts, and readiness into one lifecycle.
# These tests prove:
#   1. Stage transitions: green → next required stage, red → implementer
#   2. Surface-based required stages (security for money/auth, not for copy)
#   3. Independence: implementer and reviewer must be different agents
#   4. Claim-next: picks the next available ticket at a stage
#   5. Sweep: expired claims are returned to the queue
#   6. Blocked claimer is visible as blocked, ticket returns to queue
#   7. Apply verdict green/red/cannot-verify
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

export FM_HOME
FM_HOME=$(fm_test_tmproot fm-pipeline-lib-tests)

# shellcheck source=/dev/null
. "$ROOT/bin/fm-pipeline-lib.sh"

Q="$FM_HOME/pipeline"
STATE="$FM_HOME/state"
mkdir -p "$Q" "$STATE"

fresh_status() {
  local task=$1
  : > "$STATE/$task.status"
}

# --- stage transitions -------------------------------------------------------

test_advance_code_review_to_qa() {
  fresh_status "task-1"
  fm_pipeline_advance "$Q" "task-1" "code-review" "abc123" \
    "code-review,qa,security-review" "$STATE"
  [ -f "$Q/task-1.ready" ] || fail "ready file should exist"
  grep -q "stage=qa" "$Q/task-1.ready" || fail "ready file should have stage=qa"
  grep -q "ready-for-review: qa" "$STATE/task-1.status" || fail "status should have ready-for-review: qa"
  pass "advance code-review → qa"
}

test_advance_qa_to_security_review() {
  fresh_status "task-2"
  fm_pipeline_advance "$Q" "task-2" "qa" "abc123" \
    "code-review,qa,security-review" "$STATE"
  grep -q "stage=security-review" "$Q/task-2.ready" || fail "ready file should have stage=security-review"
  pass "advance qa → security-review"
}

test_advance_security_review_to_merge() {
  fresh_status "task-3"
  fm_pipeline_advance "$Q" "task-3" "security-review" "abc123" \
    "code-review,qa,security-review" "$STATE"
  [ ! -f "$Q/task-3.ready" ] || fail "no ready file should exist for merge stage"
  grep -q "ready-for-merge" "$STATE/task-3.status" || fail "status should have ready-for-merge"
  pass "advance security-review → merge"
}

test_advance_skips_unrequired_security() {
  fresh_status "task-skip"
  # code-review,qa only — after qa, go to merge (no security).
  fm_pipeline_advance "$Q" "task-skip" "qa" "abc123" "code-review,qa" "$STATE"
  grep -q "ready-for-merge" "$STATE/task-skip.status" || fail "should merge after qa when security not required"
  [ ! -f "$Q/task-skip.ready" ] || fail "no ready file after merge"
  pass "advance skips unrequired security-review"
}

test_return_to_implementer() {
  fresh_status "task-4"
  fm_pipeline_return "$Q" "task-4" "code-review" "3 findings" "$STATE"
  grep -q "returned: code-review returned red" "$STATE/task-4.status" || fail "status should have returned:"
  grep -q "findings=3" "$STATE/task-4.status" || fail "status should have findings count"
  pass "return to implementer after red verdict"
}

# --- surface-based required stages -------------------------------------------

test_required_stages_money_gets_security() {
  local r
  r=$(fm_pipeline_required_stages "src/wallet/buy.ts lib/payment/stripe.ts")
  printf '%s' "$r" | grep -q security-review || fail "money paths need security: $r"
  printf '%s' "$r" | grep -q qa || fail "money paths need qa: $r"
  pass "money/payment surfaces require security-review"
}

test_required_stages_auth_gets_security() {
  local r
  r=$(fm_pipeline_required_stages "server/auth/session.ts")
  printf '%s' "$r" | grep -q security-review || fail "auth needs security: $r"
  pass "auth surface requires security-review"
}

test_required_stages_docs_only() {
  local r
  r=$(fm_pipeline_required_stages "docs/readme.md copy/hero.txt")
  [ "$r" = "code-review" ] || fail "docs-only should be code-review, got $r"
  pass "docs/copy requires code-review only"
}

test_required_stages_code_gets_qa() {
  local r
  r=$(fm_pipeline_required_stages "bin/fm-foo.sh tests/fm-foo.test.sh")
  [ "$r" = "code-review,qa" ] || fail "code should be code-review,qa got $r"
  pass "ordinary code requires code-review + qa"
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

test_roles_distinct() {
  fm_pipeline_roles_distinct "a" "b" "c" || fail "distinct should pass"
  fm_pipeline_roles_distinct "a" "a" "c" 2>/dev/null && fail "impl=rev should fail"
  fm_pipeline_roles_distinct "a" "b" "a" 2>/dev/null && fail "impl=mer should fail"
  fm_pipeline_roles_distinct "a" "b" "b" 2>/dev/null && fail "rev=mer should fail"
  pass "roles_distinct pairwise checks"
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

test_claim_next_refuses_same_implementer() {
  # Isolate the queue so leftover ready markers from prior tests cannot be claimed.
  rm -f "$Q"/*.ready "$Q"/*.claim
  fm_ready_enqueue "$Q" "task-ind" "code-review" "abc123"
  printf 'implementer=reviewer-alpha\nharness=qwen\n' > "$STATE/task-ind.meta"
  if result=$(fm_pipeline_claim_next "$Q" "code-review" "reviewer-alpha" 60 "$STATE"); then
    fail "same implementer must not claim, got $result"
  fi
  pass "claim_next enforces independence when state given"
}

# --- pipeline sweep ----------------------------------------------------------

test_pipeline_sweep_expired() {
  fm_claim_acquire "$Q" "task-11" "reviewer-alpha" "abc123" "code-review" 1
  fm_ready_enqueue "$Q" "task-11" "code-review" "abc123"
  sleep 2
  fm_pipeline_sweep "$Q"
  [ ! -f "$Q/task-11.claim" ] || fail "expired claim should be removed after sweep"
  fm_ready_is_queued "$Q" "task-11" || fail "ready marker must survive expiry (ticket not lost)"
  pass "pipeline_sweep removes expired claims; ticket remains queued"
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

# --- apply verdict + blocked claimer -----------------------------------------

test_apply_verdict_green_advances() {
  fresh_status "task-av"
  fm_ready_enqueue "$Q" "task-av" "code-review" "abc123" "code-review,qa" ""
  fm_claim_acquire "$Q" "task-av" "rev-a" "abc123" "code-review" 60
  line="verdict: green [sha=abc123] [stage=code-review] [by=rev-a] [findings=0]"
  echo "$line" >> "$STATE/task-av.status"
  fm_pipeline_apply_verdict "$Q" "$STATE" "task-av" "$line" "rev-a" "code-review,qa" \
    || fail "apply green should succeed"
  grep -q "ready-for-review: qa" "$STATE/task-av.status" || fail "should advance to qa"
  fm_claim_is_active "$Q" "task-av" && fail "claim should be released"
  pass "apply green verdict advances stage"
}

test_apply_verdict_red_returns() {
  fresh_status "task-ar"
  fm_ready_enqueue "$Q" "task-ar" "code-review" "abc123"
  fm_claim_acquire "$Q" "task-ar" "rev-a" "abc123" "code-review" 60
  line="verdict: red [sha=abc123] [stage=code-review] [by=rev-a] [findings=2]"
  fm_pipeline_apply_verdict "$Q" "$STATE" "task-ar" "$line" "rev-a" \
    || fail "apply red should succeed"
  grep -q "returned:" "$STATE/task-ar.status" || fail "should return to implementer"
  pass "apply red verdict returns to implementer"
}

test_blocked_claimer_visible_and_releases() {
  fresh_status "task-blk"
  fm_ready_enqueue "$Q" "task-blk" "code-review" "abc123"
  fm_claim_acquire "$Q" "task-blk" "claimer-x" "abc123" "code-review" 60
  echo "blocked: provider refused" > "$STATE/claimer-x.status"
  out=$(fm_pipeline_release_if_claimer_blocked \
    "$Q" "$STATE" "task-blk" "$STATE/claimer-x.status") \
    || fail "should detect blocked claimer"
  printf '%s' "$out" | grep -q "BLOCKED" || fail "should print BLOCKED"
  fm_claim_is_active "$Q" "task-blk" && fail "claim should be released"
  grep -q "blocked: pipeline claimer" "$STATE/task-blk.status" \
    || fail "task status should show blocked claimer"
  pass "blocked claimer is visible and ticket returns to queue"
}

test_quota_dead_claimer_visible() {
  fresh_status "task-q"
  fm_ready_enqueue "$Q" "task-q" "qa" "abc123"
  fm_claim_acquire "$Q" "task-q" "claimer-y" "abc123" "qa" 60
  echo "limit: dead · class=limit" > "$STATE/claimer-y.status"
  out=$(fm_pipeline_release_if_claimer_blocked \
    "$Q" "$STATE" "task-q" "$STATE/claimer-y.status") \
    || fail "should detect quota death"
  printf '%s' "$out" | grep -q "quota-exhausted" || fail "should label quota-exhausted"
  pass "quota-exhausted claimer is visible as blocked, not silence"
}

# --- run all tests -----------------------------------------------------------

test_advance_code_review_to_qa
test_advance_qa_to_security_review
test_advance_security_review_to_merge
test_advance_skips_unrequired_security
test_return_to_implementer
test_required_stages_money_gets_security
test_required_stages_auth_gets_security
test_required_stages_docs_only
test_required_stages_code_gets_qa
test_independent_reviewer_passes
test_same_harness_reviewer_fails
test_roles_distinct
test_claim_next_picks_available
test_claim_next_skips_claimed
test_claim_next_refuses_same_implementer
test_pipeline_sweep_expired
test_current_stage_from_status
test_current_stage_from_verdict
test_current_stage_ready_for_merge
test_apply_verdict_green_advances
test_apply_verdict_red_returns
test_blocked_claimer_visible_and_releases
test_quota_dead_claimer_visible

printf '\n1..%d\n' 23
