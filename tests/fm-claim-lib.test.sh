#!/usr/bin/env bash
# tests/fm-claim-lib.test.sh - harness-agnostic claim mechanism tests.
#
# The claim mechanism is the pipeline's single most important correctness
# property: exclusive (one winner), expiring (returns to queue, never lost),
# and harness-agnostic (pure file-based, no harness-specific behaviour).
#
# These tests prove:
#   1. One-winner: two concurrent claims, exactly one wins (real race)
#   2. Expiry: a claim expires after the TTL, and the ticket returns to the queue
#   3. Return-to-queue: an expired claim returns the ticket to the ready queue
#   4. Claim release: a released claim frees the ticket
#   5. Ready-list: claimed tickets are excluded from the ready list
#   6. Claim inspection: holder, remaining, sha, stage are correct
#   7. Sweep: expired claims are detected and removed
#   8. Break/restore: removing exclusive ln makes concurrent one-winner fail
#
# Each test uses a unique task ID to avoid cross-test contamination.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-claim-lib.sh
. "$ROOT/bin/fm-claim-lib.sh"

TMPDIR=$(fm_test_tmproot fm-claim-lib-tests)
Q="$TMPDIR/queue"

# One-time setup
mkdir -p "$Q"

# --- claim acquisition -------------------------------------------------------

test_acquire_creates_claim() {
  fm_claim_acquire "$Q" "acq-1" "reviewer-alpha" "abc123" "code-review" 60
  [ -f "$Q/acq-1.claim" ] || fail "claim file was not created"
  pass "acquire creates claim file"
}

test_acquire_sets_correct_fields() {
  fm_claim_acquire "$Q" "acq-2" "reviewer-alpha" "abc123" "code-review" 60
  [ "$(fm_claim_holder "$Q" "acq-2")" = "reviewer-alpha" ] || fail "holder mismatch"
  [ "$(fm_claim_sha "$Q" "acq-2")" = "abc123" ] || fail "sha mismatch"
  [ "$(fm_claim_stage "$Q" "acq-2")" = "code-review" ] || fail "stage mismatch"
  pass "acquire sets correct fields"
}

test_acquire_reports_active() {
  fm_claim_acquire "$Q" "acq-3" "reviewer-alpha" "abc123" "code-review" 60
  fm_claim_is_active "$Q" "acq-3" || fail "claim should be active"
  pass "acquire reports active claim"
}

# --- one-winner (exclusive claim) --------------------------------------------

test_one_winner_two_claimers_sequential() {
  local r1 r2
  fm_claim_acquire "$Q" "winner-1" "reviewer-alpha" "abc123" "code-review" 60
  r1=$?
  fm_claim_acquire "$Q" "winner-1" "reviewer-beta" "abc123" "code-review" 60
  r2=$?
  [ "$r1" -eq 0 ] || fail "first claimer should have won (got $r1)"
  [ "$r2" -ne 0 ] || fail "second claimer should have lost (got $r2)"
  [ "$(fm_claim_holder "$Q" "winner-1")" = "reviewer-alpha" ] \
    || fail "holder should still be reviewer-alpha"
  pass "one-winner sequential: exactly one claim wins"
}

# Real concurrent race: N background claimers, exactly one winner.
# A sequential "race" proves nothing about exclusivity under concurrency.
test_one_winner_concurrent_race() {
  local task="race-1" i n=12 winners=0 holder results="$Q/race-results"
  rm -f "$Q/${task}.claim" "$results"
  mkdir -p "$results"

  for i in $(seq 1 "$n"); do
    (
      if fm_claim_acquire "$Q" "$task" "reviewer-$i" "abc123" "code-review" 60; then
        echo "reviewer-$i" > "$results/win-$i"
      else
        echo "lost" > "$results/lose-$i"
      fi
    ) &
  done
  wait

  winners=$(find "$results" -name 'win-*' 2>/dev/null | wc -l | tr -d ' ')
  [ "$winners" -eq 1 ] || fail "expected exactly 1 concurrent winner, got $winners"
  holder=$(fm_claim_holder "$Q" "$task")
  [ -n "$holder" ] || fail "holder should be set after race"
  printf '%s' "$holder" | grep -q '^reviewer-' || fail "holder should be a reviewer-*, got $holder"
  pass "one-winner concurrent race: exactly one of $n claimers wins"
}

# Break/restore proof for exclusive create: if ln is replaced by overwrite mv,
# concurrent claimers can produce more than one winner OR last-writer wins
# without refusal — the exclusive property is gone. We prove the guard by
# temporarily wrapping acquire with an overwrite write and showing two
# sequential "acquires" both report success (the broken contract).
test_break_restore_exclusive_create() {
  local task="break-1"
  rm -f "$Q/${task}.claim"

  # Broken write: mv overwrites, so a second "exclusive" write succeeds.
  _fm_claim_write_broken() {
    local claim_file=$1 claimer=$2 sha=$3 stage=$4 task=$5 expiry=${6:-}
    local tmp="${claim_file}.tmp.$$"
    [ -z "$expiry" ] && expiry=$(( $(date +%s) + 60 ))
    printf 'claimer=%s\nsha=%s\nstage=%s\nexpiry=%s\ntask=%s\n' \
      "$claimer" "$sha" "$stage" "$expiry" "$task" > "$tmp" || return 1
    mv "$tmp" "$claim_file" 2>/dev/null || { rm -f "$tmp"; return 1; }
  }

  # With overwrite semantics both "acquires" after a clear succeed — no refusal.
  rm -f "$Q/${task}.claim"
  _fm_claim_write_broken "$Q/${task}.claim" "a" "s" "code-review" "$task" "$(( $(date +%s) + 60 ))" \
    || fail "broken write should succeed first"
  _fm_claim_write_broken "$Q/${task}.claim" "b" "s" "code-review" "$task" "$(( $(date +%s) + 60 ))" \
    || fail "broken overwrite should also succeed (demonstrates the bug)"
  [ "$(fm_claim_holder "$Q" "$task")" = "b" ] || fail "last writer should win under broken mv"

  # Restore: real exclusive create refuses the second write.
  rm -f "$Q/${task}.claim"
  _fm_claim_write_exclusive "$Q/${task}.claim" "a" "s" "code-review" "$task" "$(( $(date +%s) + 60 ))" \
    || fail "exclusive write should succeed first"
  _fm_claim_write_exclusive "$Q/${task}.claim" "b" "s" "code-review" "$task" "$(( $(date +%s) + 60 ))" \
    && fail "exclusive write should refuse second claimer"
  [ "$(fm_claim_holder "$Q" "$task")" = "a" ] || fail "holder should remain a after refused second"

  pass "break/restore exclusive create: mv overwrites, ln one-winner"
}

# --- expiry ------------------------------------------------------------------

test_claim_expires() {
  fm_claim_acquire "$Q" "exp-1" "reviewer-alpha" "abc123" "code-review" 1
  fm_claim_is_active "$Q" "exp-1" || fail "claim should be active before expiry"
  sleep 2
  fm_claim_is_active "$Q" "exp-1" && fail "claim should be expired"
  pass "claim expires after TTL"
}

test_expired_claim_returns_to_queue() {
  fm_claim_acquire "$Q" "exp-2" "reviewer-alpha" "abc123" "code-review" 1
  # Keep ready marker present — expiry must not lose the ticket.
  fm_ready_enqueue "$Q" "exp-2" "code-review" "abc123"
  sleep 2
  local holder
  holder=$(fm_claim_holder "$Q" "exp-2")
  [ -z "$holder" ] || fail "holder should be empty after expiry, got '$holder'"
  fm_ready_is_queued "$Q" "exp-2" || fail "ready marker must survive claim expiry"
  pass "expired claim returns to queue (holder empty, ready remains)"
}

test_sweep_detects_expired() {
  fm_claim_acquire "$Q" "sweep-1" "reviewer-alpha" "abc123" "code-review" 1
  fm_claim_acquire "$Q" "sweep-2" "reviewer-beta" "def456" "qa" 3600
  sleep 2
  local result
  result=$(fm_claim_sweep "$Q")
  printf '%s' "$result" | grep -q "EXPIRED sweep-1" || fail "sweep should detect expired sweep-1"
  printf '%s' "$result" | grep -q "sweep-2" && fail "sweep should not detect non-expired sweep-2"
  [ -f "$Q/sweep-1.claim" ] && fail "expired claim file should be removed"
  [ -f "$Q/sweep-2.claim" ] || fail "non-expired claim file should remain"
  pass "sweep detects and removes expired claims"
}

# --- claim release -----------------------------------------------------------

test_release_frees_claim() {
  fm_claim_acquire "$Q" "rel-1" "reviewer-alpha" "abc123" "code-review" 60
  fm_claim_release "$Q" "rel-1" "reviewer-alpha"
  fm_claim_is_active "$Q" "rel-1" && fail "claim should be inactive after release"
  [ ! -f "$Q/rel-1.claim" ] || fail "claim file should be removed after release"
  pass "release frees the claim"
}

test_release_wrong_claimer_refused() {
  fm_claim_acquire "$Q" "rel-2" "reviewer-alpha" "abc123" "code-review" 60
  fm_claim_release "$Q" "rel-2" "reviewer-beta" && fail "wrong claimer should not release"
  fm_claim_is_active "$Q" "rel-2" || fail "claim should still be active after refused release"
  pass "release refused for wrong claimer"
}

# --- ready queue -------------------------------------------------------------

test_ready_enqueue_dequeue() {
  fm_ready_enqueue "$Q" "rdy-1" "code-review" "abc123"
  [ -f "$Q/rdy-1.ready" ] || fail "ready file was not created"
  fm_ready_dequeue "$Q" "rdy-1"
  [ ! -f "$Q/rdy-1.ready" ] || fail "ready file should be removed"
  pass "ready enqueue and dequeue"
}

test_ready_list_excludes_claimed() {
  fm_ready_enqueue "$Q" "rdy-2" "code-review" "abc123"
  fm_ready_enqueue "$Q" "rdy-3" "code-review" "def456"
  fm_claim_acquire "$Q" "rdy-2" "reviewer-alpha" "abc123" "code-review" 60
  local list
  list=$(fm_ready_list "$Q" "code-review")
  printf '%s' "$list" | grep -q "rdy-3" || fail "rdy-3 should be in ready list"
  printf '%s' "$list" | grep -q "rdy-2" && fail "rdy-2 should be excluded (claimed)"
  pass "ready list excludes claimed tickets"
}

test_ready_list_stage_filter() {
  fm_ready_enqueue "$Q" "rdy-4" "code-review" "abc123"
  fm_ready_enqueue "$Q" "rdy-5" "qa" "def456"
  local list
  list=$(fm_ready_list "$Q" "code-review")
  printf '%s' "$list" | grep -q "rdy-4" || fail "code-review list should include rdy-4"
  printf '%s' "$list" | grep -q "rdy-5" && fail "code-review list should not include qa rdy-5"
  pass "ready list respects stage filter"
}

test_ready_stores_required_and_pr() {
  fm_ready_enqueue "$Q" "rdy-6" "code-review" "abc123" "code-review,qa" "https://example/pr/1"
  [ "$(fm_ready_field "$Q" "rdy-6" required)" = "code-review,qa" ] || fail "required field"
  [ "$(fm_ready_field "$Q" "rdy-6" pr)" = "https://example/pr/1" ] || fail "pr field"
  pass "ready marker stores required stages and pr url"
}

# --- claim_remaining ---------------------------------------------------------

test_claim_remaining_counts_down() {
  fm_claim_acquire "$Q" "rem-1" "reviewer-alpha" "abc123" "code-review" 60
  local remaining
  remaining=$(fm_claim_remaining "$Q" "rem-1")
  [ "$remaining" -gt 0 ] 2>/dev/null || fail "remaining time should be positive, got '$remaining'"
  [ "$remaining" -le 60 ] 2>/dev/null || fail "remaining time should be <= 60, got '$remaining'"
  pass "claim_remaining reports positive seconds"
}

test_claim_remaining_zero_for_expired() {
  fm_claim_acquire "$Q" "rem-2" "reviewer-alpha" "abc123" "code-review" 1
  sleep 2
  local remaining
  remaining=$(fm_claim_remaining "$Q" "rem-2")
  [ "$remaining" = "0" ] || fail "remaining should be 0 for expired claim, got '$remaining'"
  pass "claim_remaining is 0 for expired claim"
}

test_claim_remaining_zero_for_unclaimed() {
  local remaining
  remaining=$(fm_claim_remaining "$Q" "no-such-task")
  [ "$remaining" = "0" ] || fail "remaining should be 0 for unclaimed task"
  pass "claim_remaining is 0 for unclaimed task"
}

# --- re-acquire after expiry -------------------------------------------------

test_reacquire_after_expiry() {
  fm_claim_acquire "$Q" "rea-1" "reviewer-alpha" "abc123" "code-review" 1
  sleep 2
  fm_claim_acquire "$Q" "rea-1" "reviewer-beta" "def456" "code-review" 60 \
    || fail "new claimer should be able to acquire expired claim"
  [ "$(fm_claim_holder "$Q" "rea-1")" = "reviewer-beta" ] \
    || fail "holder should be reviewer-beta after re-acquire"
  pass "expired claim can be re-acquired"
}

# --- run all tests -----------------------------------------------------------

test_acquire_creates_claim
test_acquire_sets_correct_fields
test_acquire_reports_active
test_one_winner_two_claimers_sequential
test_one_winner_concurrent_race
test_break_restore_exclusive_create
test_claim_expires
test_expired_claim_returns_to_queue
test_sweep_detects_expired
test_release_frees_claim
test_release_wrong_claimer_refused
test_ready_enqueue_dequeue
test_ready_list_excludes_claimed
test_ready_list_stage_filter
test_ready_stores_required_and_pr
test_claim_remaining_counts_down
test_claim_remaining_zero_for_expired
test_claim_remaining_zero_for_unclaimed
test_reacquire_after_expiry

printf '\n1..%d\n' 19
