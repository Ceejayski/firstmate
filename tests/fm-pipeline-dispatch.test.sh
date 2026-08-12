#!/usr/bin/env bash
# tests/fm-pipeline-dispatch.test.sh - claim + brief prepare without hand-routing.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

export FM_HOME
FM_HOME=$(fm_test_tmproot fm-pipeline-dispatch-tests)
STATE="$FM_HOME/state"
DATA="$FM_HOME/data"
PIPELINE="$FM_HOME/state/pipeline"
mkdir -p "$STATE" "$DATA" "$PIPELINE"

SHA40="dddddddddddddddddddddddddddddddddddddddd"
DISPATCH="$ROOT/bin/fm-pipeline-dispatch.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-claim-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-pipeline-lib.sh"

test_prepare_claims_and_composes_brief() {
  fm_write_meta "$STATE/d-1.meta" "kind=ship" "implementer=d-1" "harness=qwen" \
    "project=$ROOT" "pr=https://github.com/o/r/pull/20" "pr_head=$SHA40" \
    "changed_paths=bin/x.sh" "required_stages=code-review,qa" "changed_paths_sha=$SHA40"
  : > "$STATE/d-1.status"
  fm_ready_enqueue "$PIPELINE" "d-1" "code-review" "$SHA40" "code-review,qa" \
    "https://github.com/o/r/pull/20"

  out=$("$DISPATCH" --state "$STATE" --pipeline-dir "$PIPELINE" --no-spawn --stage code-review)
  printf '%s' "$out" | grep -q "PREPARED d-1" || fail "should PREPARE: $out"
  [ -f "$DATA/rvw-d-1-cr/brief.md" ] || fail "brief not written"
  holder=$(fm_claim_holder "$PIPELINE" "d-1")
  [ "$holder" = "rvw-d-1-cr" ] || fail "claimer should be rvw-d-1-cr, got $holder"
  grep -q "review-dispatched: code-review" "$STATE/d-1.status" \
    || fail "status missing review-dispatched"
  pass "prepare claims ticket and composes standing brief"
}

test_blocked_harness_releases_claim() {
  fm_write_meta "$STATE/d-harn.meta" "kind=ship" "implementer=d-harn" \
    "project=$ROOT" "pr=https://github.com/o/r/pull/23" "pr_head=$SHA40" \
    "changed_paths=bin/x.sh" "required_stages=code-review" "changed_paths_sha=$SHA40"
  : > "$STATE/d-harn.status"
  fm_ready_enqueue "$PIPELINE" "d-harn" "code-review" "$SHA40" "code-review" \
    "https://github.com/o/r/pull/23"

  # Force spawn path with no harness configured.
  unset FM_PIPELINE_REVIEW_HARNESS
  rm -f "$FM_HOME/config/crew-harness"
  out=$("$DISPATCH" --state "$STATE" --pipeline-dir "$PIPELINE" --spawn --stage code-review)
  printf '%s' "$out" | grep -q "BLOCKED-HARNESS d-harn" \
    || fail "missing harness must block: $out"
  grep -q "blocked: pipeline dispatch needs a review harness" "$STATE/d-harn.status" \
    || fail "blocked must be visible"
  fm_claim_is_active "$PIPELINE" "d-harn" && fail "claim must be released on BLOCKED-HARNESS"
  [ -f "$PIPELINE/d-harn.ready" ] || fail "ready marker must remain (ticket not lost)"
  pass "BLOCKED-HARNESS releases claim; ticket stays queued"
}

test_self_review_blocked_visible() {
  fm_write_meta "$STATE/d-self.meta" "kind=ship" "implementer=rvw-d-self-cr" \
    "pr=https://github.com/o/r/pull/21" "pr_head=$SHA40"
  : > "$STATE/d-self.status"
  fm_ready_enqueue "$PIPELINE" "d-self" "code-review" "$SHA40"

  out=$("$DISPATCH" --state "$STATE" --pipeline-dir "$PIPELINE" --no-spawn --stage code-review)
  printf '%s' "$out" | grep -q "BLOCKED-INDEPENDENCE d-self" \
    || fail "self-review claimer must block: $out"
  grep -q "blocked: pipeline independence" "$STATE/d-self.status" \
    || fail "blocked must be visible on ticket"
  fm_claim_is_active "$PIPELINE" "d-self" && fail "must not hold claim"
  pass "self-review blocked visibly, not silence"
}

test_missing_implementer_blocked() {
  fm_write_meta "$STATE/d-miss.meta" "kind=ship" "harness=qwen" \
    "pr=https://github.com/o/r/pull/22" "pr_head=$SHA40"
  : > "$STATE/d-miss.status"
  fm_ready_enqueue "$PIPELINE" "d-miss" "qa" "$SHA40"

  out=$("$DISPATCH" --state "$STATE" --pipeline-dir "$PIPELINE" --no-spawn --stage qa)
  printf '%s' "$out" | grep -q "BLOCKED-INDEPENDENCE d-miss" \
    || fail "missing implementer must block: $out"
  pass "missing implementer blocks dispatch visibly"
}

test_prepare_claims_and_composes_brief
test_self_review_blocked_visible
test_missing_implementer_blocked
test_blocked_harness_releases_claim

printf '\n1..%d\n' 4
