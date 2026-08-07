#!/usr/bin/env bash
# Contract tests for bin/fm-honest-done.sh - branch-vs-target suite measurement
# for ship done-reports.
#
# Fixtures cover:
#   - branch introduces a failure (BRANCH-INTRODUCED naming the test)
#   - branch failure set matches target (BYTE-IDENTICAL), including inherited red
#   - project with no discoverable test command (unknown, exit 0)
#   - git state (HEAD / branch / porcelain) unchanged after a run
#   - primary checkout refused without FM_HONEST_DONE_ALLOW_PRIMARY
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HONEST="$ROOT/bin/fm-honest-done.sh"
assert_present "$HONEST" "bin/fm-honest-done.sh is missing"
[ -x "$HONEST" ] || fail "bin/fm-honest-done.sh must be executable"

fm_git_identity fmtest fmtest@example.invalid

TMP_ROOT=$(fm_test_tmproot fm-honest-done)
export FM_HONEST_DONE_NO_CACHE=1
# Isolate cache even if NO_CACHE is ignored.
export TMPDIR="$TMP_ROOT/tmp"
mkdir -p "$TMPDIR"

# Build a bare origin + clone + linked worktree so the worktree is not primary.
# The suite is a TAP script whose failing set is controlled by a FAIL_TESTS
# file in the tree (so main and branch can differ after commits).
make_repo() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir"

  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main

  git clone -q "$case_dir/origin.git" "$case_dir/seed" 2>/dev/null
  # Controllable TAP suite: FAIL_TESTS is a newline-separated list of names.
  cat > "$case_dir/seed/run-suite.sh" <<'SH'
#!/usr/bin/env bash
set -u
# All known tests; those listed in FAIL_TESTS (if present) fail.
ALL="alpha beta gamma"
n=0
for t in $ALL; do
  n=$((n + 1))
  if [ -f FAIL_TESTS ] && grep -Fxq "$t" FAIL_TESTS; then
    printf 'not ok %s - %s\n' "$n" "$t"
  else
    printf 'ok %s - %s\n' "$n" "$t"
  fi
done
if [ -f FAIL_TESTS ] && [ -s FAIL_TESTS ]; then
  exit 1
fi
exit 0
SH
  chmod +x "$case_dir/seed/run-suite.sh"
  printf '%s\n' '{"scripts":{"test":"./run-suite.sh"}}' > "$case_dir/seed/package.json"
  # Empty FAIL_TESTS on main = all green.
  : > "$case_dir/seed/FAIL_TESTS"
  git -C "$case_dir/seed" add run-suite.sh package.json FAIL_TESTS
  git -C "$case_dir/seed" -c user.email=t@t -c user.name=t commit -qm "main baseline all green"
  git -C "$case_dir/seed" push -q origin main
  rm -rf "$case_dir/seed"

  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  git -C "$case_dir/project" worktree add -q -b fm/task-h1 "$case_dir/wt" main

  printf '%s\n' "$case_dir"
}

fingerprint() {
  local root=$1
  {
    git -C "$root" rev-parse HEAD
    git -C "$root" symbolic-ref -q HEAD || echo DETACHED
    git -C "$root" status --porcelain=v1
  }
}

run_honest() {
  local wt=$1
  shift
  "$HONEST" --dir "$wt" "$@"
}

test_help_and_executable() {
  local help
  help=$("$HONEST" --help 2>&1) || fail "fm-honest-done.sh --help exited non-zero"
  assert_contains "$help" "BYTE-IDENTICAL" "help missing BYTE-IDENTICAL form"
  assert_contains "$help" "BRANCH-INTRODUCED" "help missing BRANCH-INTRODUCED form"
  assert_contains "$help" "unknown" "help missing unknown discovery path"
  pass "fm-honest-done.sh: help documents the one-line form"
}

test_unknown_when_no_test_command() {
  local case_dir out rc
  case_dir=$(make_repo no-test-cmd)
  # Remove every discoverable declaration.
  rm -f "$case_dir/wt/package.json"
  git -C "$case_dir/wt" add -A
  git -C "$case_dir/wt" commit -qm "drop package.json" >/dev/null

  out=$(run_honest "$case_dir/wt" 2>/dev/null); rc=$?
  expect_code 0 "$rc" "unknown discovery must exit 0 (got $rc, out=$out)"
  [ "$out" = "unknown" ] || fail "expected exact line 'unknown', got: $out"
  pass "fm-honest-done.sh: no discoverable test command reports unknown exit 0"
}

test_branch_introduced_names_failure() {
  local case_dir out rc
  case_dir=$(make_repo introduced)
  # Main stays green. Branch fails gamma only.
  printf 'gamma\n' > "$case_dir/wt/FAIL_TESTS"
  git -C "$case_dir/wt" add FAIL_TESTS
  git -C "$case_dir/wt" commit -qm "branch breaks gamma" >/dev/null

  out=$(run_honest "$case_dir/wt" --target origin/main 2>/dev/null); rc=$?
  expect_code 0 "$rc" "measurement must exit 0 even when suite red (got $rc)"
  assert_contains "$out" "fail on branch" "missing branch side: $out"
  assert_contains "$out" "fail on target" "missing target side: $out"
  assert_contains "$out" "failure set BRANCH-INTRODUCED: gamma" \
    "expected BRANCH-INTRODUCED naming gamma, got: $out"
  # Counts: branch 2 pass / 1 fail; target 3 pass / 0 fail
  assert_contains "$out" "2 pass / 1 fail on branch" "branch counts wrong: $out"
  assert_contains "$out" "3 pass / 0 fail on target" "target counts wrong: $out"
  pass "fm-honest-done.sh: branch-introduced failure names the test"
}

test_byte_identical_including_inherited_red() {
  local case_dir out rc
  case_dir=$(make_repo inherited)
  # Put a failure on main first.
  git -C "$case_dir/project" checkout -q main
  # project is a non-worktree primary of this fixture; work on a temp side branch
  # via the shared repo by committing through the worktree after merging base red.
  # Simpler: commit red on main through a second worktree, then rebase feature.
  git -C "$case_dir/project" worktree add -q -b main-red "$case_dir/main-red" main
  printf 'alpha\n' > "$case_dir/main-red/FAIL_TESTS"
  git -C "$case_dir/main-red" add FAIL_TESTS
  git -C "$case_dir/main-red" commit -qm "main inherits alpha red" >/dev/null
  git -C "$case_dir/main-red" push -q origin main-red:main
  git -C "$case_dir/project" fetch -q origin main
  # Move worktree branch onto the red main tip + keep same FAIL_TESTS.
  git -C "$case_dir/wt" reset --hard origin/main >/dev/null

  out=$(run_honest "$case_dir/wt" --target origin/main 2>/dev/null); rc=$?
  expect_code 0 "$rc" "inherited red measurement must exit 0"
  assert_contains "$out" "2 pass / 1 fail on branch" "branch counts wrong: $out"
  assert_contains "$out" "2 pass / 1 fail on target" "target counts wrong: $out"
  assert_contains "$out" "failure set BYTE-IDENTICAL" \
    "inherited identical red must be BYTE-IDENTICAL, got: $out"
  assert_contains "$out" "BYTE-IDENTICAL" "missing BYTE-IDENTICAL: $out"
  # Must not claim BRANCH-INTRODUCED for the inherited name.
  if printf '%s' "$out" | grep -q 'BRANCH-INTRODUCED'; then
    fail "inherited red must not report BRANCH-INTRODUCED: $out"
  fi
  pass "fm-honest-done.sh: matching failure sets report BYTE-IDENTICAL"
}

test_git_state_untouched() {
  local case_dir before after out
  case_dir=$(make_repo no-mutate)
  printf 'beta\n' > "$case_dir/wt/FAIL_TESTS"
  git -C "$case_dir/wt" add FAIL_TESTS
  git -C "$case_dir/wt" commit -qm "branch fails beta" >/dev/null

  before=$(fingerprint "$case_dir/wt")
  out=$(run_honest "$case_dir/wt" --target origin/main 2>/dev/null) \
    || fail "honest-done exited non-zero during no-mutate check"
  after=$(fingerprint "$case_dir/wt")
  [ "$before" = "$after" ] || fail "git state changed:\nbefore:\n$before\nafter:\n$after\nout=$out"
  # Also ensure we did not leave the worktree on another branch tip.
  [ "$(git -C "$case_dir/wt" branch --show-current)" = "fm/task-h1" ] \
    || fail "branch name changed after run"
  pass "fm-honest-done.sh: leaves HEAD, branch, and porcelain untouched"
}

test_refuses_primary_checkout() {
  local case_dir out rc
  case_dir=$(make_repo primary-refuse)
  # $case_dir/project is the main working tree (primary).
  out=$(run_honest "$case_dir/project" --target origin/main 2>&1); rc=$?
  expect_code 2 "$rc" "primary checkout must exit 2, got $rc out=$out"
  assert_contains "$out" "primary checkout" "refusal must name primary checkout: $out"
  pass "fm-honest-done.sh: refuses primary checkout"
}

test_makefile_discovery() {
  local case_dir out rc
  case_dir=$(make_repo makefile-disc)
  rm -f "$case_dir/wt/package.json"
  cat > "$case_dir/wt/Makefile" <<'MK'
test:
	./run-suite.sh
MK
  git -C "$case_dir/wt" add -A
  git -C "$case_dir/wt" commit -qm "switch to make test" >/dev/null

  out=$(run_honest "$case_dir/wt" --target origin/main 2>/dev/null); rc=$?
  expect_code 0 "$rc" "makefile discovery run failed: $out"
  assert_contains "$out" "3 pass / 0 fail on branch" "makefile path counts wrong: $out"
  assert_contains "$out" "failure set BYTE-IDENTICAL" "makefile path label wrong: $out"
  pass "fm-honest-done.sh: discovers make test from Makefile"
}

test_script_parses() {
  local out rc
  out=$(bash -n "$HONEST" 2>&1); rc=$?
  expect_code 0 "$rc" "bash -n fm-honest-done.sh failed: $out"
  pass "fm-honest-done.sh: bash -n succeeds"
}

test_help_and_executable
test_script_parses
test_unknown_when_no_test_command
test_branch_introduced_names_failure
test_byte_identical_including_inherited_red
test_git_state_untouched
test_refuses_primary_checkout
test_makefile_discovery
