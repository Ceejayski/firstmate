#!/usr/bin/env bash
# Behavior tests for bin/fm-context-pack.sh, its resolver, and brief hook.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot context-pack)
PACK_HOME="$TMP_ROOT/home"
GRAPH_DIR="$PACK_HOME/data/context-graph"
mkdir -p "$GRAPH_DIR/recipes"

cat > "$GRAPH_DIR/recipes/firstmate-ship.yaml" <<'EOF'
name: firstmate-ship
max_tokens: 9000
always:
  - skill:firstmate-coding
  - rule:uncapped-private-memory
max_reports: 1
max_docs: 2
forbid:
  - full-captain
  - full-learnings
EOF

cat > "$GRAPH_DIR/recipes/brain-scout.yaml" <<'EOF'
name: brain-scout
max_tokens: 4000
always:
max_reports: 1
max_docs: 1
EOF

cat > "$GRAPH_DIR/graph.jsonl" <<'EOF'
{"op":"node","id":"skill:firstmate-coding","type":"skill","path":".agents/skills/firstmate-coding-guidelines/SKILL.md","repo":"firstmate","summary":"Tracked-material guidance","priority":90}
{"op":"node","id":"rule:uncapped-private-memory","type":"rule","path":"data/captain.md","repo":"-","summary":"One live rule only","priority":100}
{"op":"node","id":"rail:expected-firstmate","type":"rail","path":"data/expected-rail.md","repo":"firstmate","summary":"Expected task rail","max_lines":30,"priority":80}
{"op":"node","id":"task:known-task","type":"task","path":"data/known-task/brief.md","repo":"firstmate","summary":"Known task","priority":50}
{"op":"edge","from":"task:known-task","rel":"depends-on","to":"rail:expected-firstmate"}
EOF

printf '%s\n' '# Captain memory fixture' > "$PACK_HOME/data/captain.md"
printf '%s\n' '# Expected rail fixture' > "$PACK_HOME/data/expected-rail.md"

test_lists_recipes() {
  local output
  output=$(FM_HOME="$PACK_HOME" "$ROOT/bin/fm-context-pack.sh" --list-recipes) \
    || fail "context pack recipe listing failed"
  assert_contains "$output" "brain-scout" "recipe listing omitted brain-scout"
  assert_contains "$output" "firstmate-ship" "recipe listing omitted firstmate-ship"
  pass "fm-context-pack: recipe list comes from the active home"
}

test_known_task_pack() {
  local output
  output=$(FM_HOME="$PACK_HOME" "$ROOT/bin/fm-context-pack.sh" --task known-task --recipe firstmate-ship) \
    || fail "known task pack failed"
  assert_contains "$output" "rail:expected-firstmate" "known task pack omitted its expected rail"
  assert_contains "$output" "skill:firstmate-coding" "known task pack omitted the recipe's required skill"
  assert_contains "$output" "Full \`data/captain.md\`" "pack omitted the full-captain prohibition"
  assert_contains "$output" "path: \`data/captain.md\`; max 20 lines" \
    "uncapped captain node was not forced to a bounded read"
  if printf '%s\n' "$output" | grep -F "path: \`data/captain.md\`" | grep -vF 'max 20 lines' >/dev/null; then
    fail "pack requested an unbounded captain.md read"
  fi
  pass "fm-context-pack: known task includes its rail without full captain memory"
}

test_output_and_brief_hook() {
  local id=generated-pack brief pack output status
  id=generated-pack
  brief="$PACK_HOME/data/$id/brief.md"
  pack="$PACK_HOME/data/$id/context-pack.md"
  output=$(FM_HOME="$PACK_HOME" "$ROOT/bin/fm-brief.sh" "$id" firstmate --context-pack firstmate-ship 2>&1); status=$?
  expect_code 0 "$status" "fm-brief --context-pack should generate a pack (got: $output)"
  assert_present "$pack" "fm-brief --context-pack did not generate data/<id>/context-pack.md"
  assert_grep "# Context pack" "$brief" "generated brief omitted its context-pack section"
  assert_grep "Read this task context first: \`$pack\`" "$brief" "generated brief omitted the pack's first-read link"

  id=linked-pack
  brief="$PACK_HOME/data/$id/brief.md"
  pack="$PACK_HOME/data/$id/context-pack.md"
  mkdir -p "$(dirname "$pack")"
  printf '%s\n' '# Existing authoritative pack' > "$pack"
  FM_HOME="$PACK_HOME" "$ROOT/bin/fm-brief.sh" "$id" firstmate --context-pack >/dev/null 2>&1 \
    || fail "fm-brief failed to link an existing context pack"
  assert_grep "Existing authoritative pack" "$pack" "fm-brief overwrote an existing context pack"
  assert_grep "Read this task context first: \`$pack\`" "$brief" "brief omitted the existing pack link"
  pass "fm-brief: context-pack flag generates or links data/<id>/context-pack.md"
}

test_skill_triggers_are_registered_once() {
  local pack_count curate_count
  pack_count=$(grep -c "^- \`context-pack\` - load before every crewmate or scout dispatch" "$ROOT/AGENTS.md")
  curate_count=$(grep -c "^- \`context-graph-curate\` - load after a scout or design report lands" "$ROOT/AGENTS.md")
  [ "$pack_count" -eq 1 ] || fail "context-pack must have exactly one section 13 trigger, found $pack_count"
  [ "$curate_count" -eq 1 ] || fail "context-graph-curate must have exactly one section 13 trigger, found $curate_count"
  pass "context graph skills have precise section 13 triggers"
}

test_lists_recipes
test_known_task_pack
test_output_and_brief_hook
test_skill_triggers_are_registered_once
