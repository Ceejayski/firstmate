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
# Library-path tests: no stage-agent spawn (dispatch still prepares when ready).
export FM_PIPELINE_AUTO_SPAWN=0

# Mini git fixture for tick readiness (paths must come from a real diff).
make_tick_git() {
  local name=$1 relpath=$2
  local case_dir="$FM_HOME/git-fixtures/$name"
  mkdir -p "$case_dir"
  fm_git_identity
  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$case_dir/origin.git" "$case_dir/project" 2>/dev/null
  printf 'base\n' > "$case_dir/project/README.md"
  git -C "$case_dir/project" add README.md
  git -C "$case_dir/project" -c user.email=t@t -c user.name=t commit -qm base
  git -C "$case_dir/project" push -q origin main
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  git -C "$case_dir/project" worktree add -q -b "fm/$name" "$case_dir/wt" main
  mkdir -p "$case_dir/wt/$(dirname "$relpath")"
  printf 'x\n' > "$case_dir/wt/$relpath"
  git -C "$case_dir/wt" add "$relpath"
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t commit -qm "change"
  TICK_HEAD=$(git -C "$case_dir/wt" rev-parse HEAD)
  TICK_CASE=$case_dir
}

test_tick_ready_from_done_with_observables() {
  make_tick_git tick-1 "src/foo.ts"
  fm_write_meta "$STATE/tick-1.meta" "kind=ship" "implementer=tick-1" "harness=qwen" \
    "worktree=$TICK_CASE/wt" "project=$TICK_CASE/project" \
    "pr=https://github.com/o/r/pull/10" "pr_head=$TICK_HEAD"
  echo "done: PR https://github.com/o/r/pull/10" > "$STATE/tick-1.status"
  touch "$STATE/tick-1.turn-ended"

  out=$("$TICK" --state "$STATE" --pipeline-dir "$PIPELINE" --no-dispatch)
  printf '%s' "$out" | grep -q "READY tick-1" || fail "tick should READY tick-1: $out"
  grep -q "ready-for-review:" "$STATE/tick-1.status" || fail "status missing ready-for-review"
  [ -f "$PIPELINE/tick-1.ready" ] || fail "ready marker missing"
  req=$(grep '^required=' "$PIPELINE/tick-1.ready" | cut -d= -f2-)
  printf '%s' "$req" | grep -q "qa" || fail "ordinary code should require qa: $req"
  grep -q 'changed_paths=.*src/foo.ts' "$STATE/tick-1.meta" \
    || fail "tick must record changed_paths into meta"
  pass "tick: done:+observables → ready without orchestrator"
}

test_tick_blocks_when_paths_unknown() {
  fm_write_meta "$STATE/tick-paths.meta" "kind=ship" "implementer=tick-paths" \
    "pr=https://github.com/o/r/pull/11" "pr_head=$SHA40"
  echo "done: PR https://github.com/o/r/pull/11" > "$STATE/tick-paths.status"
  touch "$STATE/tick-paths.turn-ended"

  out=$("$TICK" --state "$STATE" --pipeline-dir "$PIPELINE" --no-dispatch)
  printf '%s' "$out" | grep -q "BLOCKED-PATHS tick-paths" \
    || fail "unknown paths must BLOCKED-PATHS: $out"
  [ ! -f "$PIPELINE/tick-paths.ready" ] || fail "must not enqueue without paths"
  grep -q "blocked: cannot determine changed paths" "$STATE/tick-paths.status" \
    || fail "blocked must be visible on ticket"
  pass "tick: unknown paths block, never generic enqueue"
}

test_tick_security_stage_reachable_from_git() {
  make_tick_git tick-sec "src/auth/session.ts"
  fm_write_meta "$STATE/tick-sec.meta" "kind=ship" "implementer=tick-sec" \
    "worktree=$TICK_CASE/wt" "project=$TICK_CASE/project" \
    "pr=https://github.com/o/r/pull/12" "pr_head=$TICK_HEAD"
  echo "done: PR https://github.com/o/r/pull/12" > "$STATE/tick-sec.status"
  touch "$STATE/tick-sec.turn-ended"

  out=$("$TICK" --state "$STATE" --pipeline-dir "$PIPELINE" --no-dispatch)
  printf '%s' "$out" | grep -q "READY tick-sec" || fail "should READY: $out"
  req=$(grep '^required=' "$PIPELINE/tick-sec.ready" | cut -d= -f2-)
  printf '%s' "$req" | grep -q "security-review" \
    || fail "auth path must reach security-review via tick, got $req"
  pass "tick: auth path end-to-end requires security-review"
}

test_tick_not_ready_done_without_pr() {
  fm_write_meta "$STATE/tick-2.meta" "kind=ship" "implementer=tick-2" "harness=qwen"
  echo "done: shipped locally" > "$STATE/tick-2.status"
  touch "$STATE/tick-2.turn-ended"

  out=$("$TICK" --state "$STATE" --pipeline-dir "$PIPELINE" --no-dispatch)
  printf '%s' "$out" | grep -q "NOT-READY tick-2" || fail "should NOT-READY: $out"
  [ ! -f "$PIPELINE/tick-2.ready" ] || fail "must not enqueue without pr"
  pass "tick: done: without PR is NOT-READY"
}

test_tick_sweep_expired_claim() {
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-claim-lib.sh"
  fm_ready_enqueue "$PIPELINE" "tick-3" "code-review" "$SHA40"
  fm_claim_acquire "$PIPELINE" "tick-3" "old-rev" "$SHA40" "code-review" 1
  sleep 2
  out=$("$TICK" --state "$STATE" --pipeline-dir "$PIPELINE" --no-dispatch)
  printf '%s' "$out" | grep -q "EXPIRED tick-3" || fail "sweep should expire: $out"
  [ ! -f "$PIPELINE/tick-3.claim" ] || fail "claim file should be gone"
  [ -f "$PIPELINE/tick-3.ready" ] || fail "ready marker must remain (ticket not lost)"
  pass "tick: expired claim returns ticket to queue"
}

test_tick_applies_green_verdict() {
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-claim-lib.sh"
  fm_write_meta "$STATE/tick-4.meta" "kind=ship" "implementer=impl" "harness=qwen"
  fm_ready_enqueue "$PIPELINE" "tick-4" "code-review" "$SHA40" "code-review,qa" ""
  fm_claim_acquire "$PIPELINE" "tick-4" "rev-a" "$SHA40" "code-review" 60
  : > "$STATE/tick-4.status"
  echo "verdict: green [sha=$SHA40] [stage=code-review] [by=rev-a] [findings=0]" \
    >> "$STATE/tick-4.status"

  out=$("$TICK" --state "$STATE" --pipeline-dir "$PIPELINE" --no-dispatch)
  printf '%s' "$out" | grep -q "APPLIED tick-4 green" || fail "should apply green: $out"
  grep -q "ready-for-review: qa" "$STATE/tick-4.status" || fail "should advance to qa"
  pass "tick: green verdict advances without hand-routing"
}

test_tick_blocked_claimer() {
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-claim-lib.sh"
  fm_write_meta "$STATE/tick-5.meta" "kind=ship" "implementer=tick-5"
  : > "$STATE/tick-5.status"
  fm_ready_enqueue "$PIPELINE" "tick-5" "qa" "$SHA40"
  fm_claim_acquire "$PIPELINE" "tick-5" "rev-block" "$SHA40" "qa" 60
  echo "blocked: out of quota" > "$STATE/rev-block.status"

  out=$("$TICK" --state "$STATE" --pipeline-dir "$PIPELINE" --no-dispatch)
  printf '%s' "$out" | grep -q "BLOCKED tick-5" || fail "should surface blocked: $out"
  grep -q "blocked: pipeline claimer" "$STATE/tick-5.status" || fail "status missing blocked"
  pass "tick: blocked claimer visible, not silence"
}

test_tick_dispatches_prepared_reviewer() {
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-claim-lib.sh"
  # Dispatch brief path still needs meta paths OR required_stages for composition.
  # Use a real firstmate file path already on disk via ROOT project + hand-set
  # required_stages bound to a fake sha is not enough for brief when paths empty
  # and required present - brief accepts required without paths.
  fm_write_meta "$STATE/tick-6.meta" "kind=ship" "implementer=tick-6" "harness=qwen" \
    "project=$ROOT" "pr=https://github.com/o/r/pull/30" "pr_head=$SHA40" \
    "changed_paths=bin/y.sh" "required_stages=code-review" "changed_paths_sha=$SHA40"
  : > "$STATE/tick-6.status"
  fm_ready_enqueue "$PIPELINE" "tick-6" "code-review" "$SHA40" "code-review" \
    "https://github.com/o/r/pull/30"

  out=$("$TICK" --state "$STATE" --pipeline-dir "$PIPELINE")
  printf '%s' "$out" | grep -qE "PREPARED tick-6|dispatch: PREPARED tick-6" \
    || fail "tick should dispatch prepare: $out"
  [ -f "$FM_HOME/data/rvw-tick-6-cr/brief.md" ] || fail "brief should exist after tick dispatch"
  pass "tick: dispatch prepares independent reviewer brief"
}

test_tick_ready_from_done_with_observables
test_tick_blocks_when_paths_unknown
test_tick_security_stage_reachable_from_git
test_tick_not_ready_done_without_pr
test_tick_sweep_expired_claim
test_tick_applies_green_verdict
test_tick_blocked_claimer
test_tick_dispatches_prepared_reviewer

printf '\n1..%d\n' 8
