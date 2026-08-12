#!/usr/bin/env bash
# tests/fm-review-brief.test.sh - standing-spec review brief composition.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

export FM_HOME
FM_HOME=$(fm_test_tmproot fm-review-brief-tests)
STATE="$FM_HOME/state"
DATA="$FM_HOME/data"
PIPELINE="$FM_HOME/state/pipeline"
mkdir -p "$STATE" "$DATA" "$PIPELINE"

SHA40="cccccccccccccccccccccccccccccccccccccccc"
BRIEF="$ROOT/bin/fm-review-brief.sh"

test_composes_code_review_brief() {
  fm_write_meta "$STATE/ship-1.meta" "kind=ship" "implementer=ship-1" "harness=qwen" \
    "project=$ROOT" "pr=https://github.com/o/r/pull/9" "pr_head=$SHA40" \
    "changed_paths=bin/fm-foo.sh"
  out=$("$BRIEF" ship-1 code-review --state "$STATE" --pipeline-dir "$PIPELINE" \
    --claimer rvw-ship-1-cr)
  [ -f "$out" ] || fail "brief path missing: $out"
  grep -q "Independently review" "$out" || fail "missing task header"
  grep -q "U1" "$out" || fail "missing universal core"
  grep -q "CR3" "$out" || fail "missing code-review checks"
  grep -q "B1" "$out" || fail "missing base/collision"
  grep -q "verdict: green|red|cannot-verify" "$out" || fail "missing verdict format"
  grep -q "sha=$SHA40" "$out" || fail "missing bound sha"
  grep -q "by=rvw-ship-1-cr" "$out" || fail "missing claimer in verdict template"
  pass "composes code-review brief from standing spec"
}

test_qa_stage_includes_adjacency() {
  fm_write_meta "$STATE/ship-2.meta" "kind=ship" "implementer=ship-2" \
    "pr=https://github.com/o/r/pull/10" "pr_head=$SHA40" \
    "changed_paths=src/components/Foo.tsx"
  out=$("$BRIEF" ship-2 qa --state "$STATE" --out "$DATA/rvw-ship-2-qa/brief.md")
  grep -q "QA2" "$out" || fail "missing QA adjacency"
  grep -q "QA6" "$out" || fail "UI flag should include QA6"
  pass "qa stage includes adjacency and UI checks"
}

test_security_stage_for_money_paths() {
  fm_write_meta "$STATE/ship-3.meta" "kind=ship" "implementer=ship-3" \
    "pr=https://github.com/o/r/pull/11" "pr_head=$SHA40" \
    "changed_paths=src/wallet/buy.ts"
  out=$("$BRIEF" ship-3 security-review --state "$STATE")
  grep -q "SEC1" "$out" || fail "missing SEC1"
  grep -q "SEC3" "$out" || fail "money should include SEC3"
  pass "security stage for money paths"
}

test_refuses_without_sha() {
  fm_write_meta "$STATE/ship-bad.meta" "kind=ship" "implementer=ship-bad" \
    "pr=https://github.com/o/r/pull/12"
  if "$BRIEF" ship-bad code-review --state "$STATE" 2>/dev/null; then
    fail "must refuse without valid sha"
  fi
  pass "refuses without valid PR head"
}

test_composes_code_review_brief
test_qa_stage_includes_adjacency
test_security_stage_for_money_paths
test_refuses_without_sha

printf '\n1..%d\n' 4
