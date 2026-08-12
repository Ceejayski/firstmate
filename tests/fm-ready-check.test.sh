#!/usr/bin/env bash
# tests/fm-ready-check.test.sh - third-party observable readiness.
#
# Readiness must not trust a self-report. A done: status line may trigger a
# check; only pr= + pr_head= (forge-reachable facts) make a ticket ready.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

export FM_HOME
FM_HOME=$(fm_test_tmproot fm-ready-check-tests)
STATE="$FM_HOME/state"
PIPELINE="$FM_HOME/state/pipeline"
mkdir -p "$STATE" "$PIPELINE"

export FM_STATE_OVERRIDE="$STATE"
export FM_PIPELINE_DIR_OVERRIDE="$PIPELINE"
export FM_HOME

# shellcheck source=/dev/null
. "$ROOT/bin/fm-ready-check.sh"

SHA40="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
SHA40B="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

write_meta() {
  local task=$1
  shift
  fm_write_meta "$STATE/$task.meta" "$@"
}

test_done_alone_not_ready() {
  write_meta "t-done" "kind=ship" "harness=qwen"
  echo "done: finished locally" > "$STATE/t-done.status"
  touch "$STATE/t-done.turn-ended"
  fm_ready_observables_ok "$STATE" "t-done" 2>/dev/null \
    && fail "done: without pr= must not be ready"
  pass "done: alone is not readiness"
}

test_pushed_branch_without_pr_not_ready() {
  write_meta "t-nopr" "kind=ship" "harness=qwen"
  # No pr=, no pr_head=
  fm_ready_observables_ok "$STATE" "t-nopr" 2>/dev/null \
    && fail "missing pr= must not be ready"
  pass "no pr= is not ready"
}

test_pr_without_head_not_ready() {
  write_meta "t-nohead" "kind=ship" "pr=https://github.com/o/r/pull/1"
  fm_ready_observables_ok "$STATE" "t-nohead" 2>/dev/null \
    && fail "pr without pr_head must not be ready"
  pass "pr without pr_head is not ready"
}

test_pr_and_head_ready() {
  write_meta "t-ok" "kind=ship" "harness=qwen" \
    "pr=https://github.com/o/r/pull/1" "pr_head=$SHA40"
  fm_ready_observables_ok "$STATE" "t-ok" || fail "pr+pr_head should be ready"
  pass "pr= and pr_head= are ready"
}

test_invalid_head_rejected() {
  write_meta "t-badsha" "kind=ship" \
    "pr=https://github.com/o/r/pull/1" "pr_head=notasha"
  fm_ready_observables_ok "$STATE" "t-badsha" 2>/dev/null \
    && fail "invalid pr_head must fail"
  pass "invalid pr_head rejected"
}

test_scout_not_ready() {
  write_meta "t-scout" "kind=scout" \
    "pr=https://github.com/o/r/pull/1" "pr_head=$SHA40"
  fm_ready_observables_ok "$STATE" "t-scout" 2>/dev/null \
    && fail "scout must not enter pipeline"
  pass "scout is not pipeline-ready"
}

# Build a mini remote+worktree with one changed path; print head SHA.
# $1: case name  $2: relative path to create under the worktree  $3: file body
make_ship_git() {
  local name=$1 relpath=$2 body=$3
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
  printf '%s\n' "$body" > "$case_dir/wt/$relpath"
  git -C "$case_dir/wt" add "$relpath"
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t commit -qm "change $relpath"
  HEAD_SHA=$(git -C "$case_dir/wt" rev-parse HEAD)
  CASE_DIR=$case_dir
}

test_enqueue_from_meta_surface_security() {
  make_ship_git t-sec "src/wallet/ledger.ts" "export const ledger = 1"
  write_meta "t-sec" "kind=ship" "implementer=t-sec" \
    "worktree=$CASE_DIR/wt" "project=$CASE_DIR/project" \
    "pr=https://github.com/o/r/pull/2" "pr_head=$HEAD_SHA"
  : > "$STATE/t-sec.status"
  stage=$(fm_ready_enqueue_from_meta "$STATE" "$PIPELINE" "t-sec") \
    || fail "enqueue should succeed for money path"
  [ "$stage" = "code-review" ] || fail "first stage should be code-review, got $stage"
  req=$(fm_ready_field "$PIPELINE" "t-sec" required)
  printf '%s' "$req" | grep -q "security-review" || fail "money/auth paths need security, got $req"
  grep -q 'changed_paths=.*src/wallet/ledger.ts' "$STATE/t-sec.meta" \
    || fail "meta must record changed_paths from git"
  grep -q "ready-for-review: code-review" "$STATE/t-sec.status" || fail "status line missing"
  pass "security surfaces require security-review stage (from real git paths)"
}

test_enqueue_docs_only_skips_security() {
  make_ship_git t-docs "docs/readme.md" "# docs only"
  write_meta "t-docs" "kind=ship" "implementer=t-docs" \
    "worktree=$CASE_DIR/wt" "project=$CASE_DIR/project" \
    "pr=https://github.com/o/r/pull/3" "pr_head=$HEAD_SHA"
  : > "$STATE/t-docs.status"
  stage=$(fm_ready_enqueue_from_meta "$STATE" "$PIPELINE" "t-docs") \
    || fail "docs enqueue should succeed"
  req=$(fm_ready_field "$PIPELINE" "t-docs" required)
  [ "$req" = "code-review" ] || fail "docs-only should be code-review only, got $req"
  [ "$stage" = "code-review" ] || fail "first stage code-review"
  pass "docs/copy skip qa and security"
}

test_cli_ready_check() {
  make_ship_git t-cli "src/foo.ts" "export const x = 1"
  write_meta "t-cli" "kind=ship" "implementer=t-cli" \
    "worktree=$CASE_DIR/wt" "project=$CASE_DIR/project" \
    "pr=https://github.com/o/r/pull/4" "pr_head=$HEAD_SHA"
  out=$("$ROOT/bin/fm-ready-check.sh" "t-cli" "$STATE") || fail "cli should exit 0"
  [ "$out" = "code-review" ] || fail "cli should print first stage, got $out"
  grep -q '^required_stages=code-review,qa' "$STATE/t-cli.meta" \
    || fail "ordinary code should record code-review,qa"
  pass "CLI ready-check enqueues and prints stage"
}

test_enqueue_without_paths_source_blocks() {
  write_meta "t-nopath" "kind=ship" "implementer=t-nopath" \
    "pr=https://github.com/o/r/pull/5" "pr_head=$SHA40"
  : > "$STATE/t-nopath.status"
  if fm_ready_enqueue_from_meta "$STATE" "$PIPELINE" "t-nopath" 2>/dev/null; then
    fail "missing git path source must not enqueue"
  fi
  grep -q "blocked: cannot determine changed paths" "$STATE/t-nopath.status" \
    || fail "must append blocked: for missing paths"
  [ ! -f "$PIPELINE/t-nopath.ready" ] || fail "must not create ready marker"
  pass "unknown paths block enqueue (never generic code-review,qa)"
}

test_cli_refuses_done_without_pr() {
  write_meta "t-cli2" "kind=ship"
  echo "done: ship it" > "$STATE/t-cli2.status"
  if "$ROOT/bin/fm-ready-check.sh" "t-cli2" "$STATE" 2>/dev/null; then
    fail "cli must refuse done without pr"
  fi
  pass "CLI refuses done without third-party PR"
}

# Break/restore: if readiness trusted last status verb done:, the guard fails.
test_break_restore_done_is_not_readiness() {
  write_meta "t-br" "kind=ship" "harness=qwen"
  echo "done: all green locally" > "$STATE/t-br.status"

  # Broken criterion (what we must not ship): last verb == done.
  last=$(tail -1 "$STATE/t-br.status")
  case "$last" in
    done:*) broken_ready=1 ;;
    *) broken_ready=0 ;;
  esac
  [ "$broken_ready" -eq 1 ] || fail "setup: done: line should look ready to the broken check"

  # Restored criterion: observables.
  fm_ready_observables_ok "$STATE" "t-br" 2>/dev/null \
    && fail "restored check must refuse done-only"
  # Add observables → ready.
  fm_write_meta "$STATE/t-br.meta" "kind=ship" "harness=qwen" \
    "pr=https://github.com/o/r/pull/9" "pr_head=$SHA40"
  fm_ready_observables_ok "$STATE" "t-br" || fail "with pr+head should be ready"
  pass "break/restore: done: is not readiness; pr+head is"
}

test_done_alone_not_ready
test_pushed_branch_without_pr_not_ready
test_pr_without_head_not_ready
test_pr_and_head_ready
test_invalid_head_rejected
test_scout_not_ready
test_enqueue_from_meta_surface_security
test_enqueue_docs_only_skips_security
test_cli_ready_check
test_enqueue_without_paths_source_blocks
test_cli_refuses_done_without_pr
test_break_restore_done_is_not_readiness

printf '\n1..%d\n' 12
