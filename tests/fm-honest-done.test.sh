#!/usr/bin/env bash
# Contract tests for bin/fm-honest-done.sh - branch-vs-target suite measurement
# for ship done-reports.
#
# Fixtures cover:
#   - branch introduces a failure (BRANCH-INTRODUCED naming the test) with --solo
#   - branch failure set matches target (BYTE-IDENTICAL), including inherited red
#   - without --solo the verdict is UNVERIFIED (counts may still print)
#   - forced contention with --solo yields CONTENDED, not a comparison verdict
#   - project with no discoverable test command (unknown, exit 0)
#   - .no-mistakes.yaml commands.test discovery, with and without python3 yaml
#   - git state (HEAD / branch / porcelain) unchanged after a run
#   - primary checkout refused without FM_HONEST_DONE_ALLOW_PRIMARY, while
#     --discover-only (read-only) still works there
#   - Vitest/Jest summary counts parse on BSD sed as well as GNU sed
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

# Solo measurement helper: asserts exclusive suite access for a real verdict.
# ASSUME_QUIET keeps fixture verdicts stable when earlier suite scripts left
# ambient processes; production ship measures never set that variable.
run_honest_solo() {
  local wt=$1
  shift
  FM_HONEST_DONE_ASSUME_QUIET=1 \
    "$HONEST" --solo --dir "$wt" "$@"
}

test_help_and_executable() {
  local help
  help=$("$HONEST" --help 2>&1) || fail "fm-honest-done.sh --help exited non-zero"
  assert_contains "$help" "BYTE-IDENTICAL" "help missing BYTE-IDENTICAL form"
  assert_contains "$help" "BRANCH-INTRODUCED" "help missing BRANCH-INTRODUCED form"
  assert_contains "$help" "UNVERIFIED" "help missing UNVERIFIED form"
  assert_contains "$help" "CONTENDED" "help missing CONTENDED form"
  assert_contains "$help" "--solo" "help missing --solo"
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

  out=$(run_honest_solo "$case_dir/wt" --target origin/main 2>/dev/null); rc=$?
  expect_code 0 "$rc" "measurement must exit 0 even when suite red (got $rc)"
  assert_contains "$out" "fail on branch" "missing branch side: $out"
  assert_contains "$out" "fail on target" "missing target side: $out"
  assert_contains "$out" "failure set BRANCH-INTRODUCED: gamma" \
    "expected BRANCH-INTRODUCED naming gamma, got: $out"
  # Counts: branch 2 pass / 1 fail; target 3 pass / 0 fail
  assert_contains "$out" "2 pass / 1 fail on branch" "branch counts wrong: $out"
  assert_contains "$out" "3 pass / 0 fail on target" "target counts wrong: $out"
  assert_contains "$out" "branch=" "solo line must name branch SHA: $out"
  assert_contains "$out" "target=" "solo line must name target SHA: $out"
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

  out=$(run_honest_solo "$case_dir/wt" --target origin/main 2>/dev/null); rc=$?
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
  out=$(run_honest_solo "$case_dir/wt" --target origin/main 2>/dev/null) \
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

# Discovery reads project files only; CI (actions/checkout) is a primary
# checkout, so --discover-only must work there without the escape hatch.
test_discover_only_allowed_in_primary_checkout() {
  local case_dir out rc
  case_dir=$(make_repo primary-discover)
  out=$(run_honest "$case_dir/project" --discover-only 2>&1); rc=$?
  expect_code 0 "$rc" "--discover-only in primary checkout must exit 0, got $rc out=$out"
  [ "$out" = "./run-suite.sh" ] || fail "expected discovered './run-suite.sh', got: $out"
  pass "fm-honest-done.sh: --discover-only works in a primary checkout"
}

# Vitest / Jest summary counts must parse on BSD sed too (no GNU \b).
test_vitest_jest_summary_counts() {
  local case_dir out rc
  case_dir=$(make_repo jest-summary)
  cat > "$case_dir/wt/run-suite.sh" <<'SH'
#!/usr/bin/env bash
set -u
ALL="alpha beta gamma"
failed=0
total=0
for t in $ALL; do
  total=$((total + 1))
  if [ -f FAIL_TESTS ] && grep -Fxq "$t" FAIL_TESTS; then
    printf 'FAIL suites/%s.test.js\n' "$t"
    failed=$((failed + 1))
  else
    printf 'PASS suites/%s.test.js\n' "$t"
  fi
done
printf 'Tests:       %s failed, %s passed, %s total\n' "$failed" "$((total - failed))" "$total"
[ "$failed" -eq 0 ] || exit 1
exit 0
SH
  chmod +x "$case_dir/wt/run-suite.sh"
  git -C "$case_dir/wt" add run-suite.sh
  git -C "$case_dir/wt" commit -qm "jest-style summary suite" >/dev/null
  # Target carries the same runner, all green.
  git -C "$case_dir/wt" push -q origin HEAD:main

  printf 'gamma\n' > "$case_dir/wt/FAIL_TESTS"
  git -C "$case_dir/wt" add FAIL_TESTS
  git -C "$case_dir/wt" commit -qm "branch breaks gamma" >/dev/null

  out=$(run_honest_solo "$case_dir/wt" --target origin/main 2>/dev/null); rc=$?
  expect_code 0 "$rc" "jest-summary measurement must exit 0 (got $rc, out=$out)"
  assert_contains "$out" "2 pass / 1 fail on branch" "jest branch counts wrong: $out"
  assert_contains "$out" "3 pass / 0 fail on target" "jest target counts wrong: $out"
  assert_contains "$out" "BRANCH-INTRODUCED: suites/gamma.test.js" \
    "jest failure name wrong: $out"
  pass "fm-honest-done.sh: parses Vitest/Jest summary counts portably"
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
  # Keep target on the same declared command so the compare is about discovery,
  # not an unparseable target tree left on the package.json baseline.
  git -C "$case_dir/wt" push -q origin HEAD:main

  out=$(run_honest_solo "$case_dir/wt" --target origin/main 2>/dev/null); rc=$?
  expect_code 0 "$rc" "makefile discovery run failed: $out"
  assert_contains "$out" "3 pass / 0 fail on branch" "makefile path counts wrong: $out"
  assert_contains "$out" "failure set BYTE-IDENTICAL" "makefile path label wrong: $out"
  pass "fm-honest-done.sh: discovers make test from Makefile"
}

# .no-mistakes.yaml commands.test is a declared source too, and it must resolve
# identically whether or not python3 can import yaml (awk structural fallback).
test_no_mistakes_yaml_discovery() {
  local case_dir out rc nopy
  case_dir=$(make_repo nm-yaml-disc)
  rm -f "$case_dir/wt/package.json"
  cat > "$case_dir/wt/.no-mistakes.yaml" <<'YML'
commands:
  lint: 'bin/lint.sh'
  test: './run-suite.sh'
YML
  git -C "$case_dir/wt" add -A
  git -C "$case_dir/wt" commit -qm "declare suite in .no-mistakes.yaml" >/dev/null

  out=$(run_honest "$case_dir/wt" --discover-only 2>&1); rc=$?
  expect_code 0 "$rc" ".no-mistakes.yaml discovery exited non-zero: $out"
  [ "$out" = "./run-suite.sh" ] || fail "expected './run-suite.sh' from commands.test, got: $out"

  # Same answer without a usable python3 (structural awk fallback path).
  nopy="$case_dir/nopy"
  mkdir -p "$nopy"
  printf '#!/bin/sh\nexit 1\n' > "$nopy/python3"
  chmod +x "$nopy/python3"
  out=$(PATH="$nopy:$PATH" run_honest "$case_dir/wt" --discover-only 2>&1); rc=$?
  expect_code 0 "$rc" ".no-mistakes.yaml awk fallback exited non-zero: $out"
  [ "$out" = "./run-suite.sh" ] || fail "awk fallback should match python parse, got: $out"

  git -C "$case_dir/wt" push -q origin HEAD:main
  out=$(run_honest_solo "$case_dir/wt" --target origin/main 2>/dev/null); rc=$?
  expect_code 0 "$rc" ".no-mistakes.yaml measurement failed: $out"
  assert_contains "$out" "3 pass / 0 fail on branch" "nm-yaml branch counts wrong: $out"
  assert_contains "$out" "failure set BYTE-IDENTICAL" "nm-yaml label wrong: $out"
  pass "fm-honest-done.sh: discovers commands.test from .no-mistakes.yaml"
}

# CI workflow discovery: portable fm-test-run lanes without package.json/Makefile.
# Uses a tiny fake fm-test-run.sh so the test does not invoke the real suite.
test_ci_portable_lanes_discovery() {
  local case_dir out rc
  case_dir=$(make_repo ci-lanes)
  rm -f "$case_dir/wt/package.json"
  mkdir -p "$case_dir/wt/.github/workflows" "$case_dir/wt/bin"
  cat > "$case_dir/wt/.github/workflows/ci.yml" <<'YML'
name: CI
jobs:
  lint:
    steps:
      - run: bin/fm-lint.sh
  tests-portable-parallel-1:
    steps:
      - run: |
          set -eu
          bin/fm-test-run.sh --lane portable-parallel-1 \
            --json "$RUNNER_TEMP/a.json"
  tests-portable-parallel-2:
    steps:
      - run: bin/fm-test-run.sh --lane portable-parallel-2 --json x.json
  tests-portable-serial:
    steps:
      - run: bin/fm-test-run.sh --lane portable-serial
  tests-herdr:
    steps:
      - run: bin/fm-test-run.sh --family real-herdr-gated --fail-on-gate-skip 'herdr not found'
  coverage:
    steps:
      - run: bin/fm-test-run.sh --check-coverage
YML
  # Fake runner: emit FM_TEST_SUMMARY like the real owner; one "script" per lane.
  cat > "$case_dir/wt/bin/fm-test-run.sh" <<'SH'
#!/usr/bin/env bash
set -eu
lane=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --lane) lane=$2; shift 2 ;;
    --lane=*) lane=${1#--lane=}; shift ;;
    --json|--json=*) shift; [ "${1:-}" = "${1#--}" ] && shift || true ;;
    *) shift ;;
  esac
done
printf 'FM_TEST_BEGIN 2026-01-01T00:00:00Z tests/%s.test.sh family=x expected_gate_skip=none\n' "$lane"
printf 'FM_TEST_END 2026-01-01T00:00:00Z tests/%s.test.sh exit=0 duration_ms=1 gate_skip=false\n' "$lane"
printf 'FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0 duration_ms=1\n' 
exit 0
SH
  chmod +x "$case_dir/wt/bin/fm-test-run.sh"
  git -C "$case_dir/wt" add -A
  git -C "$case_dir/wt" commit -qm "ci-only suite discovery" >/dev/null

  # Also put the same tree on origin/main so target resolves the fake runner.
  git -C "$case_dir/wt" push -q origin HEAD:main

  out=$(run_honest_solo "$case_dir/wt" --target origin/main 2>/dev/null); rc=$?
  expect_code 0 "$rc" "CI discovery measurement failed: $out"
  # Three lanes x 1 = 3 pass each side.
  assert_contains "$out" "3 pass / 0 fail on branch" "CI lane composition counts wrong: $out"
  assert_contains "$out" "3 pass / 0 fail on target" "CI target counts wrong: $out"
  assert_contains "$out" "failure set BYTE-IDENTICAL" "CI path label wrong: $out"
  pass "fm-honest-done.sh: discovers and composes CI portable fm-test-run lanes"
}

test_without_solo_reports_unverified() {
  local case_dir out rc
  case_dir=$(make_repo no-solo)
  out=$(run_honest "$case_dir/wt" --target origin/main 2>/dev/null); rc=$?
  expect_code 0 "$rc" "non-solo measure must still exit 0"
  assert_contains "$out" "3 pass / 0 fail on branch" "non-solo counts still required: $out"
  assert_contains "$out" "failure set UNVERIFIED" "without --solo must be UNVERIFIED, got: $out"
  if printf '%s' "$out" | grep -qE 'failure set (BYTE-IDENTICAL|BRANCH-INTRODUCED)'; then
    fail "without --solo must not emit a comparison verdict: $out"
  fi
  pass "fm-honest-done.sh: without --solo reports UNVERIFIED"
}

test_contended_solo_reports_contended() {
  local case_dir out rc
  case_dir=$(make_repo contended)
  out=$(
    FM_HONEST_DONE_FORCE_CONTENDED=1 \
      run_honest_solo "$case_dir/wt" --target origin/main 2>/dev/null
  ); rc=$?
  expect_code 0 "$rc" "contended measure must still exit 0"
  assert_contains "$out" "failure set CONTENDED" "solo+contention must be CONTENDED, got: $out"
  if printf '%s' "$out" | grep -qE 'failure set (BYTE-IDENTICAL|BRANCH-INTRODUCED)'; then
    fail "contended run must not emit a comparison verdict: $out"
  fi
  pass "fm-honest-done.sh: contended solo reports CONTENDED not a verdict"
}

# firstmate itself: CI is the discoverable source when package/Makefile/nm miss.
test_firstmate_repo_discovers_ci_not_unknown() {
  local out
  out=$("$HONEST" --dir "$ROOT" --discover-only 2>/dev/null) \
    || fail "discover-only on firstmate worktree exited non-zero"
  [ "$out" != "unknown" ] || fail "firstmate repo discovery returned unknown; CI should provide portable lanes"
  assert_contains "$out" "portable-parallel-1" "firstmate CI discovery missing parallel-1: $out"
  assert_contains "$out" "portable-parallel-2" "firstmate CI discovery missing parallel-2: $out"
  assert_contains "$out" "portable-serial" "firstmate CI discovery missing serial: $out"
  if printf '%s' "$out" | grep -q 'real-herdr'; then
    fail "portable measurement must not pull herdr-gated lane: $out"
  fi
  pass "fm-honest-done.sh: firstmate repo discovers CI portable lanes (not unknown)"
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
test_discover_only_allowed_in_primary_checkout
test_vitest_jest_summary_counts
test_makefile_discovery
test_no_mistakes_yaml_discovery
test_ci_portable_lanes_discovery
test_without_solo_reports_unverified
test_contended_solo_reports_contended
test_firstmate_repo_discovers_ci_not_unknown
