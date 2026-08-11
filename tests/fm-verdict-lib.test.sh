#!/usr/bin/env bash
# tests/fm-verdict-lib.test.sh - SHA-bound verdict contract tests.
#
# A verdict is the pipeline's handoff between stages. Its correctness properties:
#   1. SHA-bound: a verdict on SHA A must not be used to merge SHA B
#   2. Well-formed: every verdict has outcome, sha, stage, and reviewer
#   3. Stage progression: green → next stage, red → back to implementer
#   4. Harness-agnostic: a verdict is just a formatted status line
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-verdict-lib.sh"

# --- verdict construction ----------------------------------------------------

test_verdict_build_green() {
  local line
  line=$(_fm_verdict_build green "abc123" "code-review" "reviewer-alpha" 0)
  printf '%s' "$line" | grep -q "verdict: green" || fail "missing 'verdict: green'"
  printf '%s' "$line" | grep -q "\[sha=abc123\]" || fail "missing sha"
  printf '%s' "$line" | grep -q "\[stage=code-review\]" || fail "missing stage"
  printf '%s' "$line" | grep -q "\[by=reviewer-alpha\]" || fail "missing reviewer"
  printf '%s' "$line" | grep -q "\[findings=0\]" || fail "missing findings"
  pass "verdict build green"
}

test_verdict_build_red() {
  local line
  line=$(_fm_verdict_build red "def456" "qa" "reviewer-beta" 3)
  printf '%s' "$line" | grep -q "verdict: red" || fail "missing 'verdict: red'"
  printf '%s' "$line" | grep -q "\[findings=3\]" || fail "missing findings count"
  pass "verdict build red"
}

test_verdict_build_cannot_verify() {
  local line
  line=$(_fm_verdict_build cannot-verify "ghi789" "security-review" "reviewer-gamma")
  printf '%s' "$line" | grep -q "verdict: cannot-verify" || fail "missing 'verdict: cannot-verify'"
  printf '%s' "$line" | grep -q "findings" && fail "should not have findings field"
  pass "verdict build cannot-verify without findings"
}

# --- verdict parsing ---------------------------------------------------------

test_verdict_outcome_parsing() {
  local green red cv
  green=$(_fm_verdict_build green "abc123" "code-review" "rv" 0)
  red=$(_fm_verdict_build red "abc123" "code-review" "rv" 1)
  cv=$(_fm_verdict_build cannot-verify "abc123" "code-review" "rv")
  [ "$(fm_verdict_outcome "$green")" = green ] || fail "green outcome mismatch"
  [ "$(fm_verdict_outcome "$red")" = red ] || fail "red outcome mismatch"
  [ "$(fm_verdict_outcome "$cv")" = cannot-verify ] || fail "cannot-verify outcome mismatch"
  pass "verdict outcome parsing"
}

test_verdict_field_extraction() {
  local line
  line=$(_fm_verdict_build green "abc123" "code-review" "reviewer-alpha" 2)
  [ "$(fm_verdict_sha "$line")" = "abc123" ] || fail "sha extraction"
  [ "$(fm_verdict_stage "$line")" = "code-review" ] || fail "stage extraction"
  [ "$(fm_verdict_reviewer "$line")" = "reviewer-alpha" ] || fail "reviewer extraction"
  [ "$(fm_verdict_findings "$line")" = "2" ] || fail "findings extraction"
  pass "verdict field extraction"
}

# --- verdict validation ------------------------------------------------------

test_verdict_is_valid() {
  local line
  line=$(_fm_verdict_build green "abc123" "code-review" "rv" 0)
  fm_verdict_is_valid "$line" || fail "valid verdict should be valid"
  pass "valid verdict passes validation"
}

test_verdict_is_valid_rejects_missing_fields() {
  fm_verdict_is_valid "verdict: green" && fail "missing sha should be invalid"
  fm_verdict_is_valid "verdict: green [sha=abc123]" && fail "missing stage should be invalid"
  fm_verdict_is_valid "verdict: green [sha=abc123] [stage=code-review]" && fail "missing reviewer should be invalid"
  pass "invalid verdicts are rejected"
}

# --- SHA binding -------------------------------------------------------------

test_verdict_sha_matches() {
  local line
  line=$(_fm_verdict_build green "abc123" "code-review" "rv" 0)
  fm_verdict_sha_matches "$line" "abc123" || fail "matching SHA should pass"
  fm_verdict_sha_matches "$line" "def456" && fail "non-matching SHA should fail"
  pass "SHA binding: verdict bound to exact SHA"
}

# --- stage progression -------------------------------------------------------

test_stage_progression() {
  [ "$(fm_verdict_next_stage code-review)" = "qa" ] || fail "code-review → qa"
  [ "$(fm_verdict_next_stage qa)" = "security-review" ] || fail "qa → security-review"
  [ "$(fm_verdict_next_stage security-review)" = "merge" ] || fail "security-review → merge"
  pass "stage progression: code-review → qa → security-review → merge"
}

test_stage_reversal() {
  [ "$(fm_verdict_prev_stage qa)" = "code-review" ] || fail "qa ← code-review"
  [ "$(fm_verdict_prev_stage security-review)" = "qa" ] || fail "security-review ← qa"
  [ "$(fm_verdict_prev_stage merge)" = "security-review" ] || fail "merge ← security-review"
  pass "stage reversal"
}

test_invalid_stage_rejected() {
  ! fm_verdict_next_stage "nonexistent" || fail "unknown next stage should fail"
  ! fm_verdict_prev_stage "code-review" || fail "first stage should have no prev"
  pass "invalid stages are rejected"
}

# --- verdict classification --------------------------------------------------

test_verdict_is_green_red_cannot_verify() {
  local green red cv
  green=$(_fm_verdict_build green "abc123" "code-review" "rv" 0)
  red=$(_fm_verdict_build red "abc123" "code-review" "rv" 1)
  cv=$(_fm_verdict_build cannot-verify "abc123" "code-review" "rv")
  fm_verdict_is_green "$green" || fail "green should be green"
  fm_verdict_is_red "$red" || fail "red should be red"
  fm_verdict_is_cannot_verify "$cv" || fail "cannot-verify should be cannot-verify"
  ! fm_verdict_is_green "$red" || fail "red should not be green"
  ! fm_verdict_is_green "$cv" || fail "cannot-verify should not be green"
  pass "verdict classification"
}

# --- run all tests -----------------------------------------------------------

test_verdict_build_green
test_verdict_build_red
test_verdict_build_cannot_verify
test_verdict_outcome_parsing
test_verdict_field_extraction
test_verdict_is_valid
test_verdict_is_valid_rejects_missing_fields
test_verdict_sha_matches
test_stage_progression
test_stage_reversal
test_invalid_stage_rejected
test_verdict_is_green_red_cannot_verify

printf '\n1..%d\n' 12