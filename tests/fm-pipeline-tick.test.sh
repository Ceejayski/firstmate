#!/usr/bin/env bash
# tests/fm-pipeline-tick.test.sh - self-running tick without orchestrator routing.
#
# Scenarios:
#   - implementer finishes (done:) + observables → ready without hand-routing
#   - done: without PR stays NOT-READY (never claims invisible work)
#   - expired claim returns to queue on tick sweep
#   - blocked claimer surfaces as blocked
#   - green verdict applied advances stage
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

export FM_HOME
FM_HOME=$(fm_test_tmproot fm-pipeline-tick-tests)
STATE="$FM_HOME/state"
PIPELINE="$FM_HOME/state/pipeline"
mkdir -p "$STATE" "$PIPELINE"

SHA40="cccccccccccccccccccccccccccccccccccccccc"
TICK="$ROOT/bin/fm-pipeline-tick.sh"

test_tick_ready_from_done_with_observables() {
  fm_write_meta "$STATE/tick-1.meta" "kind=ship" "harness=qwen" \
    "pr=https://github.com/o/r/pull/10" "pr_head=$SHA40" \
    "changed_paths=src/foo.ts"
  echo "done: PR https://github.com/o/r/pull/10" > "$STATE/tick-1.status"
  touch "$STATE/tick-1.turn-ended"

  out=$("$TICK" --state "$STATE" --pipeline-dir "$PIPELINE")
  printf '%s' "$out" | grep -q "READY tick-1" || fail "tick should READY tick-1: $out"
  grep -q "ready-for-review:" "$STATE/tick-1.status" || fail "status missing ready-for-review"
  [ -f "$PIPELINE/tick-1.ready" ] || fail "ready marker missing"
  pass "tick: done:+observables → ready without orchestrator"
}

test_tick_not_ready_done_without_pr() {
  fm_write_meta "$STATE/tick-2.meta" "kind=ship" "harness=qwen"
  echo "done: shipped locally" > "$STATE/tick-2.status"
  touch "$STATE/tick-2.turn-ended"

  out=$("$TICK" --state "$STATE" --pipeline-dir "$PIPELINE")
  printf '%s' "$out" | grep -q "NOT-READY tick-2" || fail "should NOT-READY: $out"
  [ ! -f "$PIPELINE/tick-2.ready" ] || fail "must not enqueue without pr"
  pass "tick: done: without PR is NOT-READY"
}

test_tick_sweep_expired_claim() {
  # shellcheck source=bin/fm-claim-lib.sh
  . "$ROOT/bin/fm-claim-lib.sh"
  fm_ready_enqueue "$PIPELINE" "tick-3" "code-review" "$SHA40"
  fm_claim_acquire "$PIPELINE" "tick-3" "old-rev" "$SHA40" "code-review" 1
  sleep 2
  out=$("$TICK" --state "$STATE" --pipeline-dir "$PIPELINE")
  printf '%s' "$out" | grep -q "EXPIRED tick-3" || fail "sweep should expire: $out"
  [ ! -f "$PIPELINE/tick-3.claim" ] || fail "claim file should be gone"
  [ -f "$PIPELINE/tick-3.ready" ] || fail "ready marker must remain (ticket not lost)"
  pass "tick: expired claim returns ticket to queue"
}

test_tick_applies_green_verdict() {
  # shellcheck source=bin/fm-claim-lib.sh
  . "$ROOT/bin/fm-claim-lib.sh"
  fm_write_meta "$STATE/tick-4.meta" "kind=ship" "implementer=impl" "harness=qwen"
  fm_ready_enqueue "$PIPELINE" "tick-4" "code-review" "$SHA40" "code-review,qa" ""
  fm_claim_acquire "$PIPELINE" "tick-4" "rev-a" "$SHA40" "code-review" 60
  : > "$STATE/tick-4.status"
  echo "verdict: green [sha=$SHA40] [stage=code-review] [by=rev-a] [findings=0]" \
    >> "$STATE/tick-4.status"

  out=$("$TICK" --state "$STATE" --pipeline-dir "$PIPELINE")
  printf '%s' "$out" | grep -q "APPLIED tick-4 green" || fail "should apply green: $out"
  grep -q "ready-for-review: qa" "$STATE/tick-4.status" || fail "should advance to qa"
  pass "tick: green verdict advances without hand-routing"
}

test_tick_blocked_claimer() {
  # shellcheck source=bin/fm-claim-lib.sh
  . "$ROOT/bin/fm-claim-lib.sh"
  fm_write_meta "$STATE/tick-5.meta" "kind=ship"
  : > "$STATE/tick-5.status"
  fm_ready_enqueue "$PIPELINE" "tick-5" "qa" "$SHA40"
  fm_claim_acquire "$PIPELINE" "tick-5" "rev-block" "$SHA40" "qa" 60
  echo "blocked: out of quota" > "$STATE/rev-block.status"

  out=$("$TICK" --state "$STATE" --pipeline-dir "$PIPELINE")
  printf '%s' "$out" | grep -q "BLOCKED tick-5" || fail "should surface blocked: $out"
  grep -q "blocked: pipeline claimer" "$STATE/tick-5.status" || fail "status missing blocked"
  pass "tick: blocked claimer visible, not silence"
}

test_tick_ready_from_done_with_observables
test_tick_not_ready_done_without_pr
test_tick_sweep_expired_claim
test_tick_applies_green_verdict
test_tick_blocked_claimer

printf '\n1..%d\n' 5
