#!/usr/bin/env bash
# tests/fm-merge-gate.test.sh - SHA-bound independent merge gate.
#
# Merge acts on independent verdicts bound to the current PR head. Stale
# verdicts, red verdicts, open ask-user, and same-agent roles never merge.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

export FM_HOME
FM_HOME=$(fm_test_tmproot fm-merge-gate-tests)
STATE="$FM_HOME/state"
mkdir -p "$STATE"

# shellcheck source=bin/fm-merge-gate.sh
. "$ROOT/bin/fm-merge-gate.sh"

SHA_A="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
SHA_B="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
REQ="code-review,qa,security-review"

fresh() {
  local task=$1
  : > "$STATE/$task.status"
  fm_write_meta "$STATE/$task.meta" "kind=ship" "harness=qwen" "implementer=impl-1" \
    "pr=https://github.com/o/r/pull/1" "pr_head=$SHA_A"
}

append_verdict() {
  local task=$1 outcome=$2 sha=$3 stage=$4 by=$5
  echo "verdict: $outcome [sha=$sha] [stage=$stage] [by=$by] [findings=0]" \
    >> "$STATE/$task.status"
}

test_green_all_stages_opens_gate() {
  fresh "m-ok"
  append_verdict "m-ok" green "$SHA_A" code-review "rev-code"
  append_verdict "m-ok" green "$SHA_A" qa "rev-qa"
  append_verdict "m-ok" green "$SHA_A" security-review "rev-sec"
  out=$(fm_merge_gate_check "$STATE" "m-ok" "$SHA_A" "$REQ" "merger-1") \
    || fail "gate should open, got $out"
  [ "$out" = ok ] || fail "expected ok, got $out"
  pass "green required stages at current SHA open the gate"
}

test_stale_verdict_refuses() {
  fresh "m-stale"
  append_verdict "m-stale" green "$SHA_A" code-review "rev-code"
  append_verdict "m-stale" green "$SHA_A" qa "rev-qa"
  append_verdict "m-stale" green "$SHA_A" security-review "rev-sec"
  # PR moved to SHA_B — verdicts on SHA_A are stale.
  out=$(fm_merge_gate_check "$STATE" "m-stale" "$SHA_B" "$REQ" "merger-1" 2>/dev/null) \
    && fail "stale verdicts must refuse"
  printf '%s' "$out" | grep -qi 'stale\|missing' || fail "reason should mention stale/missing: $out"
  pass "stale verdict (PR moved) does not merge"
}

test_red_verdict_refuses() {
  fresh "m-red"
  append_verdict "m-red" green "$SHA_A" code-review "rev-code"
  append_verdict "m-red" red "$SHA_A" qa "rev-qa"
  out=$(fm_merge_gate_check "$STATE" "m-red" "$SHA_A" "code-review,qa" "merger-1" 2>/dev/null) \
    && fail "red must refuse"
  printf '%s' "$out" | grep -qi red || fail "reason should mention red: $out"
  pass "red verdict never merges"
}

test_missing_stage_refuses() {
  fresh "m-miss"
  append_verdict "m-miss" green "$SHA_A" code-review "rev-code"
  out=$(fm_merge_gate_check "$STATE" "m-miss" "$SHA_A" "code-review,qa" "merger-1" 2>/dev/null) \
    && fail "missing qa must refuse"
  pass "missing required stage refuses"
}

test_open_needs_decision_refuses() {
  fresh "m-ask"
  append_verdict "m-ask" green "$SHA_A" code-review "rev-code"
  echo "needs-decision: expand product contract?" >> "$STATE/m-ask.status"
  out=$(fm_merge_gate_check "$STATE" "m-ask" "$SHA_A" "code-review" "merger-1" 2>/dev/null) \
    && fail "open ask-user must refuse"
  printf '%s' "$out" | grep -qi 'needs-decision\|escalate' \
    || fail "reason should mention needs-decision: $out"
  pass "open needs-decision reaches escalation, not merge"
}

test_resolved_decision_allows() {
  fresh "m-res"
  append_verdict "m-res" green "$SHA_A" code-review "rev-code"
  echo "needs-decision: expand?" >> "$STATE/m-res.status"
  echo "resolved: captain said no expansion" >> "$STATE/m-res.status"
  out=$(fm_merge_gate_check "$STATE" "m-res" "$SHA_A" "code-review" "merger-1") \
    || fail "resolved decision should allow, got $out"
  pass "resolved needs-decision does not block merge"
}

test_implementer_as_reviewer_refuses() {
  fresh "m-self"
  append_verdict "m-self" green "$SHA_A" code-review "impl-1"
  out=$(fm_merge_gate_check "$STATE" "m-self" "$SHA_A" "code-review" "merger-1" 2>/dev/null) \
    && fail "implementer reviewing own work must refuse"
  pass "implementer-as-reviewer refuses"
}

test_implementer_as_merger_refuses() {
  fresh "m-mer"
  append_verdict "m-mer" green "$SHA_A" code-review "rev-code"
  out=$(fm_merge_gate_check "$STATE" "m-mer" "$SHA_A" "code-review" "impl-1" 2>/dev/null) \
    && fail "implementer as merger must refuse"
  pass "implementer-as-merger refuses"
}

test_docs_only_required_skips_security() {
  fresh "m-docs"
  append_verdict "m-docs" green "$SHA_A" code-review "rev-code"
  out=$(fm_merge_gate_check "$STATE" "m-docs" "$SHA_A" "code-review" "merger-1") \
    || fail "docs-only code-review green should open, got $out"
  pass "docs-only required set needs only code-review green"
}

test_cannot_verify_refuses() {
  fresh "m-cv"
  append_verdict "m-cv" cannot-verify "$SHA_A" code-review "rev-code"
  out=$(fm_merge_gate_check "$STATE" "m-cv" "$SHA_A" "code-review" "merger-1" 2>/dev/null) \
    && fail "cannot-verify must refuse"
  pass "cannot-verify escalates, does not merge"
}

# Break/restore: if SHA binding is ignored, a moved PR would wrongly pass.
test_break_restore_sha_binding() {
  fresh "m-br"
  append_verdict "m-br" green "$SHA_A" code-review "rev-code"

  # Broken: accept any green for stage regardless of SHA.
  broken_ok=0
  if grep -q "verdict: green" "$STATE/m-br.status"; then
    broken_ok=1
  fi
  [ "$broken_ok" -eq 1 ] || fail "setup"

  # Restored gate refuses when current head is SHA_B.
  fm_merge_gate_check "$STATE" "m-br" "$SHA_B" "code-review" "merger-1" 2>/dev/null \
    && fail "restored gate must refuse stale SHA"
  # Same SHA opens.
  fm_merge_gate_check "$STATE" "m-br" "$SHA_A" "code-review" "merger-1" \
    || fail "matching SHA must open"
  pass "break/restore SHA binding: ignore-SHA would pass; gate refuses stale"
}

test_cli_ok() {
  fresh "m-cli"
  append_verdict "m-cli" green "$SHA_A" code-review "rev-code"
  out=$("$ROOT/bin/fm-merge-gate.sh" "m-cli" "$SHA_A" "code-review" \
    --state "$STATE" --merger "merger-1") || fail "cli should ok"
  [ "$out" = ok ] || fail "cli output $out"
  pass "CLI merge-gate ok path"
}

test_green_all_stages_opens_gate
test_stale_verdict_refuses
test_red_verdict_refuses
test_missing_stage_refuses
test_open_needs_decision_refuses
test_resolved_decision_allows
test_implementer_as_reviewer_refuses
test_implementer_as_merger_refuses
test_docs_only_required_skips_security
test_cannot_verify_refuses
test_break_restore_sha_binding
test_cli_ok

printf '\n1..%d\n' 12
