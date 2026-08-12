#!/usr/bin/env bash
# tests/fm-pipeline-lib.test.sh - pipeline stage tracking and transition tests.
#
# The pipeline ties claims, verdicts, and readiness into one lifecycle.
# These tests prove:
#   1. Stage transitions: green → next required stage, red → implementer
#   2. Surface-based required stages (security for money/auth, not for copy)
#   3. Independence: fail-closed; implementer and reviewer must be different agents
#   4. Claim-next: always requires state_dir; picks next available ticket
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

test_required_stages_empty_fails_closed() {
  local r
  if r=$(fm_pipeline_required_stages "" 2>/dev/null); then
    fail "empty paths must refuse, got: $r"
  fi
  if r=$(fm_pipeline_required_stages "   " 2>/dev/null); then
    fail "whitespace-only paths must refuse, got: $r"
  fi
  pass "empty/unknown paths refuse generic stage default"
}

# Break: empty paths return code-review,qa (the production hole). Restore must refuse.
test_break_restore_empty_paths_not_generic() {
  broken_required_stages() {
    local paths=${1:-}
    if [ -z "$paths" ]; then
      printf 'code-review,qa'
      return 0
    fi
    fm_pipeline_required_stages "$paths"
  }
  r=$(broken_required_stages "")
  [ "$r" = "code-review,qa" ] || fail "setup: broken default should be code-review,qa"
  if r=$(fm_pipeline_required_stages "" 2>/dev/null); then
    fail "restored required_stages must refuse empty paths, got $r"
  fi
  r=$(fm_pipeline_required_stages "src/wallet/ledger.ts")
  printf '%s' "$r" | grep -q security-review || fail "money path still needs security: $r"
  pass "break/restore: empty paths no longer degrade to code-review,qa"
}

# End-to-end: real git diff of a money path records paths and requires security-review.
test_record_changed_paths_from_git_security() {
  local case_dir proj wt head paths required
  fm_git_identity
  case_dir=$(fm_test_tmproot fm-paths-sec)
  mkdir -p "$case_dir"
  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$case_dir/origin.git" "$case_dir/project" 2>/dev/null
  printf 'base\n' > "$case_dir/project/README.md"
  git -C "$case_dir/project" add README.md
  git -C "$case_dir/project" -c user.email=t@t -c user.name=t commit -qm base
  git -C "$case_dir/project" push -q origin main
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  git -C "$case_dir/project" worktree add -q -b fm/ship-sec "$case_dir/wt" main
  mkdir -p "$case_dir/wt/src/wallet"
  printf 'export function debit() {}\n' > "$case_dir/wt/src/wallet/ledger.ts"
  git -C "$case_dir/wt" add src/wallet/ledger.ts
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t commit -qm "money path"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)

  printf 'kind=ship\nworktree=%s\nproject=%s\npr=https://github.com/o/r/pull/99\npr_head=%s\nimplementer=ship-sec\n' \
    "$case_dir/wt" "$case_dir/project" "$head" > "$STATE/ship-sec.meta"

  paths=$(fm_pipeline_record_changed_paths "$STATE" "ship-sec") \
    || fail "record_changed_paths should succeed from real git"
  printf '%s' "$paths" | grep -q 'src/wallet/ledger.ts' \
    || fail "paths should include wallet ledger: $paths"
  grep -q '^changed_paths=.*src/wallet/ledger.ts' "$STATE/ship-sec.meta" \
    || fail "meta missing changed_paths"
  required=$(grep '^required_stages=' "$STATE/ship-sec.meta" | cut -d= -f2-)
  printf '%s' "$required" | grep -q 'security-review' \
    || fail "money path must require security-review end-to-end, got $required"
  grep -q "^changed_paths_sha=$head" "$STATE/ship-sec.meta" \
    || fail "meta must bind paths to head sha"
  pass "record_changed_paths from git makes security-review reachable"
}

test_record_changed_paths_missing_git_blocks() {
  printf 'kind=ship\npr=https://github.com/o/r/pull/1\npr_head=%s\n' \
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" > "$STATE/no-git.meta"
  if fm_pipeline_record_changed_paths "$STATE" "no-git" 2>/dev/null; then
    fail "missing git objects must not silently succeed"
  fi
  pass "missing git for paths is a hard failure"
}

test_record_changed_paths_recomputes_on_head_move() {
  local case_dir head1 head2 required
  fm_git_identity
  case_dir=$(fm_test_tmproot fm-paths-move)
  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$case_dir/origin.git" "$case_dir/project" 2>/dev/null
  printf 'base\n' > "$case_dir/project/README.md"
  git -C "$case_dir/project" add README.md
  git -C "$case_dir/project" -c user.email=t@t -c user.name=t commit -qm base
  git -C "$case_dir/project" push -q origin main
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  git -C "$case_dir/project" worktree add -q -b fm/ship-mv "$case_dir/wt" main
  mkdir -p "$case_dir/wt/docs"
  printf 'copy only\n' > "$case_dir/wt/docs/note.md"
  git -C "$case_dir/wt" add docs/note.md
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t commit -qm docs
  head1=$(git -C "$case_dir/wt" rev-parse HEAD)

  printf 'kind=ship\nworktree=%s\nproject=%s\npr=https://github.com/o/r/pull/7\npr_head=%s\n' \
    "$case_dir/wt" "$case_dir/project" "$head1" > "$STATE/ship-mv.meta"
  fm_pipeline_record_changed_paths "$STATE" "ship-mv" >/dev/null \
    || fail "initial record should work"
  required=$(grep '^required_stages=' "$STATE/ship-mv.meta" | cut -d= -f2-)
  [ "$required" = "code-review" ] || fail "docs-only should be code-review, got $required"

  mkdir -p "$case_dir/wt/src/payment"
  printf 'pay()\n' > "$case_dir/wt/src/payment/charge.ts"
  git -C "$case_dir/wt" add src/payment/charge.ts
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t commit -qm payment
  head2=$(git -C "$case_dir/wt" rev-parse HEAD)
  _fm_pipeline_meta_set_pr_head "$STATE/ship-mv.meta" "$head2"
  fm_pipeline_record_changed_paths "$STATE" "ship-mv" >/dev/null \
    || fail "recompute after head move should work"
  required=$(grep '^required_stages=' "$STATE/ship-mv.meta" | cut -d= -f2-)
  printf '%s' "$required" | grep -q security-review \
    || fail "after money path lands, security-review required, got $required"
  grep -q "^changed_paths_sha=$head2" "$STATE/ship-mv.meta" || fail "paths sha must track head"
  pass "paths recompute when head moves (docs → payment)"
}

# --- independence enforcement (fail closed) ----------------------------------

test_independent_reviewer_passes() {
  printf 'implementer=ship-task-5\nharness=qwen\n' > "$STATE/task-5.meta"
  fm_pipeline_independent "$STATE" "task-5" "rvw-task-5-cr" \
    || fail "different agent ids should be independent"
  pass "independent reviewer passes (different agent id)"
}

test_same_implementer_fails() {
  printf 'implementer=ship-task-6\nharness=qwen\n' > "$STATE/task-6.meta"
  fm_pipeline_independent "$STATE" "task-6" "ship-task-6" 2>/dev/null \
    && fail "same implementer id must fail independence"
  pass "same implementer id fails independence"
}

test_empty_implementer_fails_closed() {
  printf 'harness=qwen\n' > "$STATE/task-empty.meta"
  fm_pipeline_independent "$STATE" "task-empty" "reviewer-x" 2>/dev/null \
    && fail "empty implementer must fail closed (not allow)"
  pass "empty implementer fails closed"
}

test_empty_reviewer_fails_closed() {
  printf 'implementer=ship-x\n' > "$STATE/task-er.meta"
  fm_pipeline_independent "$STATE" "task-er" "" 2>/dev/null \
    && fail "empty reviewer must fail closed"
  pass "empty reviewer fails closed"
}

test_same_harness_different_agents_allowed() {
  # Harness is not agent identity — two Qwen agents must remain independent.
  printf 'implementer=ship-qwen-a\nharness=qwen\n' > "$STATE/task-harness.meta"
  fm_pipeline_independent "$STATE" "task-harness" "rvw-qwen-b" \
    || fail "same harness with different agent ids must be independent"
  pass "same harness, different agent ids allowed"
}

test_roles_distinct() {
  fm_pipeline_roles_distinct "a" "b" "c" || fail "distinct should pass"
  fm_pipeline_roles_distinct "a" "a" "c" 2>/dev/null && fail "impl=rev should fail"
  fm_pipeline_roles_distinct "a" "b" "a" 2>/dev/null && fail "impl=mer should fail"
  fm_pipeline_roles_distinct "a" "b" "b" 2>/dev/null && fail "rev=mer should fail"
  fm_pipeline_roles_distinct "" "b" "c" 2>/dev/null && fail "empty impl should fail closed"
  pass "roles_distinct pairwise checks (fail closed on empty impl)"
}

test_break_restore_independence_fail_open() {
  # Break: empty implementer allows (the Ship 2 hole). Prove restored code refuses.
  printf 'harness=only\n' > "$STATE/task-br.meta"
  if fm_pipeline_independent "$STATE" "task-br" "any-reviewer" 2>/dev/null; then
    fail "restored independence must refuse empty implementer"
  fi
  # With durable id, distinct claimer passes.
  printf 'implementer=ship-br\n' > "$STATE/task-br.meta"
  fm_pipeline_independent "$STATE" "task-br" "rvw-br-cr" \
    || fail "distinct ids should pass after restore"
  # Same id fails.
  fm_pipeline_independent "$STATE" "task-br" "ship-br" 2>/dev/null \
    && fail "same id must fail after restore"
  pass "break/restore independence: empty refuses; distinct passes; match refuses"
}

# --- claim next --------------------------------------------------------------

test_claim_next_requires_state_dir() {
  rm -f "$Q"/*.ready "$Q"/*.claim
  fm_ready_enqueue "$Q" "task-ns" "code-review" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  printf 'implementer=impl-ns\n' > "$STATE/task-ns.meta"
  if fm_pipeline_claim_next "$Q" "code-review" "reviewer-alpha" 2>/dev/null; then
    fail "claim_next without state_dir must refuse"
  fi
  pass "claim_next requires state_dir (no fail-open omit)"
}

test_claim_next_picks_available() {
  rm -f "$Q"/*.ready "$Q"/*.claim
  SHA40="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  fm_ready_enqueue "$Q" "task-7" "code-review" "$SHA40"
  fm_ready_enqueue "$Q" "task-8" "code-review" "$SHA40"
  printf 'implementer=impl-7\n' > "$STATE/task-7.meta"
  printf 'implementer=impl-8\n' > "$STATE/task-8.meta"
  local result
  result=$(fm_pipeline_claim_next "$Q" "code-review" "reviewer-alpha" "$STATE")
  [ -n "$result" ] || fail "should have claimed a ticket"
  printf '%s' "$result" | grep -q "task-" || fail "should return task-id and sha"
  local count
  count=$(fm_ready_list "$Q" "code-review" | grep -c '^' 2>/dev/null || printf '0')
  [ "$count" -eq 1 ] || fail "one ticket should remain, got $count"
  pass "claim_next picks one available ticket"
}

test_claim_next_skips_claimed() {
  rm -f "$Q"/*.ready "$Q"/*.claim
  SHA40="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  fm_ready_enqueue "$Q" "task-9" "code-review" "$SHA40"
  fm_ready_enqueue "$Q" "task-10" "code-review" "$SHA40"
  printf 'implementer=impl-9\n' > "$STATE/task-9.meta"
  printf 'implementer=impl-10\n' > "$STATE/task-10.meta"
  fm_claim_acquire "$Q" "task-9" "other-reviewer" "$SHA40" "code-review" 60
  local result
  result=$(fm_pipeline_claim_next "$Q" "code-review" "reviewer-alpha" "$STATE")
  printf '%s' "$result" | grep -q "task-10" || fail "should pick task-10 (task-9 claimed)"
  pass "claim_next skips claimed tickets"
}

test_claim_next_refuses_same_implementer() {
  rm -f "$Q"/*.ready "$Q"/*.claim
  SHA40="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  fm_ready_enqueue "$Q" "task-ind" "code-review" "$SHA40"
  printf 'implementer=reviewer-alpha\nharness=qwen\n' > "$STATE/task-ind.meta"
  if result=$(fm_pipeline_claim_next "$Q" "code-review" "reviewer-alpha" "$STATE"); then
    fail "same implementer must not claim, got $result"
  fi
  pass "claim_next always enforces independence"
}

test_claim_next_refuses_missing_implementer() {
  rm -f "$Q"/*.ready "$Q"/*.claim
  SHA40="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  fm_ready_enqueue "$Q" "task-miss" "code-review" "$SHA40"
  printf 'harness=qwen\n' > "$STATE/task-miss.meta"
  if result=$(fm_pipeline_claim_next "$Q" "code-review" "reviewer-beta" "$STATE" 2>/dev/null); then
    fail "missing implementer must not claim, got $result"
  fi
  pass "claim_next refuses missing implementer identity"
}

# --- pipeline sweep ----------------------------------------------------------

test_pipeline_sweep_expired() {
  SHA40="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  fm_claim_acquire "$Q" "task-11" "reviewer-alpha" "$SHA40" "code-review" 1
  fm_ready_enqueue "$Q" "task-11" "code-review" "$SHA40"
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
  SHA40="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  fresh_status "task-av"
  fm_ready_enqueue "$Q" "task-av" "code-review" "$SHA40" "code-review,qa" ""
  fm_claim_acquire "$Q" "task-av" "rev-a" "$SHA40" "code-review" 60
  line="verdict: green [sha=$SHA40] [stage=code-review] [by=rev-a] [findings=0]"
  echo "$line" >> "$STATE/task-av.status"
  fm_pipeline_apply_verdict "$Q" "$STATE" "task-av" "$line" "rev-a" "code-review,qa" \
    || fail "apply green should succeed"
  grep -q "ready-for-review: qa" "$STATE/task-av.status" || fail "should advance to qa"
  fm_claim_is_active "$Q" "task-av" && fail "claim should be released"
  pass "apply green verdict advances stage"
}

test_apply_verdict_red_returns() {
  SHA40="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  fresh_status "task-ar"
  fm_ready_enqueue "$Q" "task-ar" "code-review" "$SHA40"
  fm_claim_acquire "$Q" "task-ar" "rev-a" "$SHA40" "code-review" 60
  line="verdict: red [sha=$SHA40] [stage=code-review] [by=rev-a] [findings=2]"
  fm_pipeline_apply_verdict "$Q" "$STATE" "task-ar" "$line" "rev-a" \
    || fail "apply red should succeed"
  grep -q "returned:" "$STATE/task-ar.status" || fail "should return to implementer"
  pass "apply red verdict returns to implementer"
}

test_blocked_claimer_visible_and_releases() {
  SHA40="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  fresh_status "task-blk"
  fm_ready_enqueue "$Q" "task-blk" "code-review" "$SHA40"
  fm_claim_acquire "$Q" "task-blk" "claimer-x" "$SHA40" "code-review" 60
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
  SHA40="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  fresh_status "task-q"
  fm_ready_enqueue "$Q" "task-q" "qa" "$SHA40"
  fm_claim_acquire "$Q" "task-q" "claimer-y" "$SHA40" "qa" 60
  echo "limit: dead · class=limit" > "$STATE/claimer-y.status"
  out=$(fm_pipeline_release_if_claimer_blocked \
    "$Q" "$STATE" "task-q" "$STATE/claimer-y.status") \
    || fail "should detect quota death"
  printf '%s' "$out" | grep -q "quota-exhausted" || fail "should label quota-exhausted"
  pass "quota-exhausted claimer is visible as blocked, not silence"
}

test_reviewer_task_id_stable() {
  id=$(fm_pipeline_reviewer_task_id "ship-abc" "code-review")
  [ "$id" = "rvw-ship-abc-cr" ] || fail "got $id"
  id=$(fm_pipeline_reviewer_task_id "ship-abc" "security-review")
  [ "$id" = "rvw-ship-abc-sec" ] || fail "got $id"
  pass "reviewer task id is stable per ticket+stage"
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
test_required_stages_empty_fails_closed
test_break_restore_empty_paths_not_generic
test_record_changed_paths_from_git_security
test_record_changed_paths_missing_git_blocks
test_record_changed_paths_recomputes_on_head_move
test_independent_reviewer_passes
test_same_implementer_fails
test_empty_implementer_fails_closed
test_empty_reviewer_fails_closed
test_same_harness_different_agents_allowed
test_roles_distinct
test_break_restore_independence_fail_open
test_claim_next_requires_state_dir
test_claim_next_picks_available
test_claim_next_skips_claimed
test_claim_next_refuses_same_implementer
test_claim_next_refuses_missing_implementer
test_pipeline_sweep_expired
test_current_stage_from_status
test_current_stage_from_verdict
test_current_stage_ready_for_merge
test_apply_verdict_green_advances
test_apply_verdict_red_returns
test_blocked_claimer_visible_and_releases
test_quota_dead_claimer_visible
test_reviewer_task_id_stable

printf '\n1..%d\n' 35
