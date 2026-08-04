#!/usr/bin/env bash
# Behavior tests for the verified Qwen Code CLI crewmate adapter.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-qwen-harness)
PYTHON_BIN=$(command -v python3) || fail "test needs python3"
PYTHON_BIN_DIR=$(dirname "$PYTHON_BIN")
BASE_PATH=${FM_TEST_BASE_PATH:-$PYTHON_BIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin}

assert_source_line() {
  local line=$1 file=${2:-$SPAWN} why=${3:-}
  grep -Fqx -- "$line" "$file" || fail "${why:-existing launch template changed}: $line"
}

# The whole point of adding an adapter is that no other adapter moves. Pin every
# pre-existing launch template byte-for-byte, including Kimi's, which the Qwen
# work sits directly beside in the same case statement.
test_existing_launch_templates_are_byte_pinned() {
  assert_source_line "    claude) printf '%s' 'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions __MODELFLAG____EFFORTFLAG__\"\$(__OPINPUT__ encode launch-brief < __BRIEF__)\"' ;;"
  assert_source_line "        printf '%s' 'codex __MODELFLAG____EFFORTFLAG__--dangerously-bypass-approvals-and-sandbox \"\$(__OPINPUT__ encode launch-brief < __BRIEF__)\"'"
  assert_source_line "    opencode) printf '%s' 'OPENCODE_CONFIG_CONTENT='\\''{\"permission\":{\"*\":\"allow\"}}'\\'' opencode __MODELFLAG__--prompt \"\$(__OPINPUT__ encode launch-brief < __BRIEF__)\"' ;;"
  assert_source_line "        printf '%s%s' \"\$harness\" ' __MODELFLAG____EFFORTFLAG__-e __PIEXT__ \"\$(__OPINPUT__ encode launch-brief < __BRIEF__)\"'"
  assert_source_line "    grok) printf '%s' 'grok --always-approve __MODELFLAG____EFFORTFLAG__\"\$(__OPINPUT__ encode launch-brief < __BRIEF__)\"' ;;"
  assert_source_line "    kimi) printf '%s' '__KIMIBIN__ __MODELFLAG__--auto' ;;"
  pass "fm-spawn: every pre-existing adapter's launch template stays byte-pinned"
}

# A fake tmux that renders the qwen screens this adapter must tell apart: the
# blocking built-in-provider-update prompt, an ordinary working session, and the
# race where the composer renders first and the prompt arrives after it.
make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
state=$(cat "$FM_FAKE_QWEN_STATE" 2>/dev/null || true)
fake_screen() {
  case "$state" in
    dialog)
      printf '  Built-in Provider Update \xc2\xb7 Token Plan\n  1. Update all\n  2. Skip this version\n  3. Remind me later (esc)\n'
      ;;
    working)
      printf '  .. Counting electrons... (12s \xc2\xb7 \xe2\x86\x91 909 tokens \xc2\xb7 esc to cancel)\n*   Type your message or @path/to/file\n'
      ;;
    docprose)
      # A crewmate legitimately reading this repo's own harness docs: the modal's
      # phrase and every one of its answers are on screen, inside a sentence.
      printf '  On every interactive launch qwen raises a modal `Built-in Provider Update \xc2\xb7 <provider>` prompt offering `1. Update all`, `2. Skip this version`, `3. Remind me later (esc)`.\n'
      printf '*   Type your message or @path/to/file\n'
      ;;
    late)
      # The composer is already up; the modal lands on the NEXT poll.
      printf '  .. Counting electrons... (12s \xc2\xb7 \xe2\x86\x91 909 tokens \xc2\xb7 esc to cancel)\n*   Type your message or @path/to/file\n'
      printf 'dialog\n' > "$FM_FAKE_QWEN_STATE"
      ;;
    *)
      printf 'shell starting\n$ \n'
      ;;
  esac
}
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "$FM_FAKE_PANE_PATH"; exit 0 ;;
  *"#{cursor_y}"*) printf '1\n'; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    prev=
    literal=
    for arg in "$@"; do
      if [ "$prev" = -l ]; then literal=$arg; break; fi
      prev=$arg
    done
    if [ -n "$literal" ]; then
      case "$literal" in
        *qwen*) printf '%s\n' "$literal" >> "$FM_FAKE_LAUNCH_LOG" ;;
      esac
      exit 0
    fi
    case " $* " in
      *' Escape '*)
        printf '%s\n' "Escape" >> "$FM_FAKE_KEY_LOG"
        # A qwen that ignores Escape: the modal stays up no matter the budget.
        [ "${FM_FAKE_QWEN_STICKY_DIALOG:-0}" = 1 ] \
          || printf 'working\n' > "$FM_FAKE_QWEN_STATE"
        ;;
      *' Enter '*) printf '%s\n' "${FM_FAKE_QWEN_AFTER_LAUNCH:-working}" > "$FM_FAKE_QWEN_STATE" ;;
    esac
    exit 0
    ;;
  capture-pane) fake_screen; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh qwen
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config" "$home/.qwen"
  # A stand-in for the captain's real credential-bearing settings file. No test
  # here may change its bytes.
  printf '{"env":{"SECRET_KEY":"do-not-touch"},"providerMetadata":{"token-plan":{"version":"abc"}}}\n' \
    > "$home/.qwen/settings.json"
  printf 'brief for qwen\n' > "$home/data/$id/brief.md"
  printf 'qwen\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  : > "$case_dir/launch.log"
  : > "$case_dir/key.log"
  : > "$case_dir/qwen.state"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

run_spawn() {
  local case_dir=$1 home=$2 proj=$3 wt=$4 fakebin=$5 id=$6
  shift 6
  HOME="$home" FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" \
    FM_FAKE_KEY_LOG="$case_dir/key.log" \
    FM_FAKE_QWEN_STATE="$case_dir/qwen.state" \
    FM_FAKE_QWEN_AFTER_LAUNCH="${FM_FAKE_QWEN_AFTER_LAUNCH:-working}" \
    FM_FAKE_QWEN_STICKY_DIALOG="${FM_FAKE_QWEN_STICKY_DIALOG:-0}" \
    FM_QWEN_STARTUP_POLLS="${FM_QWEN_STARTUP_POLLS:-2}" FM_QWEN_POLL_INTERVAL=0 \
    PATH="$fakebin:$BASE_PATH" \
    "$SPAWN" "$id" "$proj" --harness qwen "$@" 2>&1
}

read_spawn_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

test_qwen_launch_is_verified() {
  local id rec out rc launch meta excl
  id=qwen-success-q1
  rec=$(make_spawn_case success "$id")
  read_spawn_record "$rec"
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" \
    --model deepseek-v4-pro --effort high)
  rc=$?
  expect_code 0 "$rc" "verified qwen launch should succeed"
  assert_contains "$out" "spawned $id harness=qwen" "qwen spawn did not report success"

  launch=$(cat "$CASE_DIR/launch.log")
  assert_contains "$launch" "QWEN_CODE_SUPPRESS_YOLO_WARNING=1 qwen --yolo --model 'deepseek-v4-pro' -i " \
    "qwen launch lost its verified autonomy, model, or interactive shape"
  assert_contains "$launch" "encode launch-brief <" \
    "qwen launch lost the canonical typed launch-brief envelope"
  assert_not_contains "$launch" "--effort" "qwen launch emitted a nonexistent effort flag"
  assert_not_contains "$launch" "--reasoning-effort" "qwen launch emitted a nonexistent effort flag"
  assert_not_contains "$launch" "--fallback-model" \
    "qwen launch enabled a silent model swap that would contradict the recorded model"
  assert_not_contains "$launch" "turn-ended" "qwen launch embedded a turn-end path"
  assert_not_contains "$launch" "-p " "qwen launch used the one-shot non-interactive flag"

  meta="$HOME_DIR/state/$id.meta"
  assert_grep 'harness=qwen' "$meta" "qwen meta lost its harness identity"
  assert_grep 'model=deepseek-v4-pro' "$meta" "qwen meta lost the requested model"
  assert_grep 'effort=high' "$meta" "qwen meta did not retain the unsupported effort axis"

  assert_grep 'token=' "$WT_DIR/.fm-qwen-turnend" "qwen spawn did not write its token pointer"
  assert_present "$HOME_DIR/state/$id.qwen-turnend-token" "qwen spawn did not record its token"
  assert_present "$HOME_DIR/.qwen/extensions/firstmate-turn-end/qwen-extension.json" \
    "qwen spawn did not install its guarded turn-end extension"
  assert_present "$HOME_DIR/.qwen/extensions/firstmate-turn-end/fm-turn-end.sh" \
    "qwen spawn did not install its guarded turn-end hook script"
  assert_grep '"Stop"' "$HOME_DIR/.qwen/extensions/firstmate-turn-end/qwen-extension.json" \
    "qwen turn-end extension did not register the Stop event"

  excl=$(git -C "$WT_DIR" rev-parse --git-path info/exclude)
  assert_grep '.fm-qwen-turnend' "$excl" "qwen token pointer was not excluded from the worktree"
  assert_grep '.qwen/settings.json' "$excl" "qwen workspace settings were not excluded from the worktree"
  [ -z "$(git -C "$WT_DIR" status --porcelain)" ] \
    || fail "qwen spawn left the worktree dirty, which would block teardown"
  pass "fm-spawn: qwen launches interactively, unattended, and registers a guarded turn-end token"
}

# The captain's provider credentials live in the same file qwen would rewrite if
# firstmate answered the provider-update prompt persistently. Firstmate answers it
# by neutralizing the check per worktree instead, so that file must never change.
test_qwen_spawn_never_writes_the_captain_settings_file() {
  local id rec before after
  id=qwen-settings-q2
  rec=$(make_spawn_case settings "$id")
  read_spawn_record "$rec"
  before=$(cat "$HOME_DIR/.qwen/settings.json")
  run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" >/dev/null \
    || fail "qwen spawn should succeed"
  after=$(cat "$HOME_DIR/.qwen/settings.json")
  [ "$before" = "$after" ] || fail "qwen spawn modified the captain's credential-bearing settings file"
  assert_grep '"providerMetadata": null' "$WT_DIR/.qwen/settings.json" \
    "qwen spawn did not suppress the provider-update prompt for this worktree"
  pass "fm-spawn: qwen suppresses the startup prompt per worktree and never edits captain settings"
}

test_qwen_spawn_preserves_a_project_owned_workspace_settings_file() {
  local id rec original
  id=qwen-preserve-q3
  rec=$(make_spawn_case preserve "$id")
  read_spawn_record "$rec"
  mkdir -p "$WT_DIR/.qwen"
  original='{"ui":{"theme":"project-owned"}}'
  printf '%s\n' "$original" > "$WT_DIR/.qwen/settings.json"
  run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" >/dev/null \
    || fail "qwen spawn should succeed"
  [ "$(cat "$WT_DIR/.qwen/settings.json")" = "$original" ] \
    || fail "qwen spawn overwrote a project-owned workspace settings file"
  pass "fm-spawn: qwen never overwrites a project's own workspace settings"
}

test_qwen_startup_prompt_is_dismissed_only_when_present() {
  local id rec keys
  id=qwen-dialog-q4
  rec=$(make_spawn_case dialog "$id")
  read_spawn_record "$rec"
  FM_FAKE_QWEN_AFTER_LAUNCH=dialog \
    run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" >/dev/null \
    || fail "qwen spawn should succeed through the startup prompt"
  keys=$(cat "$CASE_DIR/key.log")
  assert_contains "$keys" "Escape" "the blocking provider-update prompt was not dismissed"

  id=qwen-nodialog-q5
  rec=$(make_spawn_case nodialog "$id")
  read_spawn_record "$rec"
  FM_FAKE_QWEN_AFTER_LAUNCH=working \
    run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" >/dev/null \
    || fail "qwen spawn should succeed with no startup prompt"
  keys=$(cat "$CASE_DIR/key.log")
  assert_not_contains "$keys" "Escape" \
    "a working qwen pane received a blind Escape, which would cancel its first turn"
  pass "fm-spawn: the qwen startup-prompt backstop fires only on the prompt itself"
}

test_qwen_turnend_hook_requires_a_registered_workspace_token() {
  local id rec hook token registry marker workspace
  id=qwen-hook-q6
  rec=$(make_spawn_case hook "$id")
  read_spawn_record "$rec"
  run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" >/dev/null \
    || fail "qwen spawn should succeed"
  hook="$HOME_DIR/.qwen/extensions/firstmate-turn-end/fm-turn-end.sh"
  token=$(sed -n 's/^token=//p' "$WT_DIR/.fm-qwen-turnend")
  registry="$HOME_DIR/.qwen/fm-turn-end.d"
  marker="$HOME_DIR/state/$id.turn-ended"
  workspace="$WT_DIR"

  QWEN_PROJECT_DIR="$workspace" HOME="$HOME_DIR" bash "$hook" \
    || fail "the qwen turn-end hook did not exit zero"
  assert_present "$marker" "the qwen turn-end hook did not touch the task marker"

  # A workspace with no pointer is every other qwen session on this machine.
  rm -f "$marker"
  QWEN_PROJECT_DIR="$TMP_ROOT" HOME="$HOME_DIR" bash "$hook" \
    || fail "the qwen turn-end hook did not exit zero outside a firstmate workspace"
  assert_absent "$marker" "the qwen turn-end hook fired for an unrelated workspace"

  # A pointer naming an unregistered token must not resolve.
  printf 'token=fm.zzzzzzzzzzzz\n' > "$WT_DIR/.fm-qwen-turnend"
  QWEN_PROJECT_DIR="$workspace" HOME="$HOME_DIR" bash "$hook" \
    || fail "the qwen turn-end hook did not exit zero for an unregistered token"
  assert_absent "$marker" "the qwen turn-end hook honored an unregistered token"

  # A registry entry naming a non-turn-end path must not be touched.
  printf 'token=%s\n' "$token" > "$WT_DIR/.fm-qwen-turnend"
  printf '%s\n' "$HOME_DIR/state/not-a-marker" > "$registry/$token"
  QWEN_PROJECT_DIR="$workspace" HOME="$HOME_DIR" bash "$hook" \
    || fail "the qwen turn-end hook did not exit zero for a rejected target"
  assert_absent "$HOME_DIR/state/not-a-marker" "the qwen turn-end hook touched an arbitrary path"
  pass "fm-spawn: the qwen turn-end hook is silent and fires only for a registered task"
}

# The backstop must survive the race it exists for: a modal that arrives AFTER the
# composer has already rendered. A gate that stands down on the first idle-looking
# capture would leave the crewmate wedged behind a pane that reads healthy.
test_qwen_startup_prompt_is_dismissed_when_it_arrives_late() {
  local id rec keys
  id=qwen-latedialog-q4b
  rec=$(make_spawn_case latedialog "$id")
  read_spawn_record "$rec"
  FM_FAKE_QWEN_AFTER_LAUNCH=late FM_QWEN_STARTUP_POLLS=4 \
    run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" >/dev/null \
    || fail "qwen spawn should succeed through a late startup prompt"
  keys=$(cat "$CASE_DIR/key.log")
  assert_contains "$keys" "Escape" \
    "a provider-update prompt raised after the composer rendered was never dismissed"
  pass "fm-spawn: the qwen startup-prompt backstop still catches a late prompt"
}

# The detector reads pane content, and this repo documents the dialog, so a
# crewmate reading the harness-adapters skill renders the modal's own phrase. The
# gate must not treat that as the modal: Escapes would cancel its live first turn
# and the spawn would then hard-fail an agent that is working fine.
test_qwen_startup_backstop_ignores_the_dialog_quoted_in_prose() {
  local id rec out rc keys
  id=qwen-docprose-q4d
  rec=$(make_spawn_case docprose "$id")
  read_spawn_record "$rec"
  out=$(FM_FAKE_QWEN_AFTER_LAUNCH=docprose \
    run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  rc=$?
  expect_code 0 "$rc" "a qwen pane merely rendering the dialog's documentation failed its spawn"
  assert_contains "$out" "spawned $id harness=qwen" \
    "a healthy qwen crewmate reading this repo's own docs was not spawned"
  keys=$(cat "$CASE_DIR/key.log")
  assert_not_contains "$keys" "Escape" \
    "the dialog's phrase in a rendered file drew an Escape into a live first turn"
  pass "fm-spawn: the qwen startup backstop reads the modal's structure, not its prose"
}

# A dialog that outlives the Escape budget means the brief was never delivered.
# Reporting "spawned" for that pane is a false success: firstmate and every
# script that trusts the exit code would supervise a crewmate that never got its
# task. The gate must fail closed instead.
test_qwen_spawn_fails_when_the_startup_prompt_never_clears() {
  local id rec out rc status
  id=qwen-stuckdialog-q4c
  rec=$(make_spawn_case stuckdialog "$id")
  read_spawn_record "$rec"
  out=$(FM_FAKE_QWEN_AFTER_LAUNCH=dialog FM_FAKE_QWEN_STICKY_DIALOG=1 \
    run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  rc=$?
  [ "$rc" -ne 0 ] || fail "a qwen spawn wedged behind the provider-update dialog exited 0"
  assert_not_contains "$out" "spawned $id" \
    "a qwen spawn that never delivered its brief still reported success"
  assert_contains "$out" "built-in-provider-update dialog" \
    "the spawn failure did not name the blocker a supervisor has to clear"
  status="$HOME_DIR/state/$id.status"
  grep -q '^failed: ' "$status" 2>/dev/null \
    || fail "a wedged qwen spawn left no failed: line on the task status file"
  assert_grep 'built-in-provider-update dialog' "$status" \
    "the failed: line did not name the blocking dialog"
  pass "fm-spawn: a qwen startup prompt that never clears fails the spawn loudly"
}

run_qwen_teardown() {
  local id=$1; shift
  HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 PATH="$FAKEBIN_DIR:$BASE_PATH" \
    "$TEARDOWN" "$id" "$@" >/dev/null 2>&1
}

# fm-spawn refuses to overwrite a workspace settings file it did not write, so
# teardown must refuse to delete one. Otherwise a project's own qwen config - or
# one the crewmate authored as its actual task - is silently destroyed.
test_qwen_teardown_preserves_a_project_owned_workspace_settings_file() {
  local id rec original
  id=qwen-teardown-preserve-q7b
  rec=$(make_spawn_case teardown-preserve "$id")
  read_spawn_record "$rec"
  mkdir -p "$WT_DIR/.qwen"
  original='{"ui":{"theme":"project-owned"}}'
  printf '%s\n' "$original" > "$WT_DIR/.qwen/settings.json"
  run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" >/dev/null \
    || fail "qwen spawn should succeed before teardown"

  run_qwen_teardown "$id" --force || fail "qwen teardown failed"
  assert_absent "$WT_DIR/.fm-qwen-turnend" "qwen teardown did not run its worktree cleanup"
  [ "$(cat "$WT_DIR/.qwen/settings.json" 2>/dev/null)" = "$original" ] \
    || fail "qwen teardown destroyed a project-owned workspace settings file"
  pass "fm-teardown: a workspace settings file firstmate did not write survives teardown"
}

# qwen rewrites the file in place at runtime to record its own "$version", so
# ownership cannot be an exact byte match against what spawn wrote.
# The payload here is the EXACT text a real qwen 0.21.5 run left in a live
# worktree: the value is a JSON NUMBER. An ownership test that tolerated only a
# quoted string passed its own unit case and still leaked this file on every
# real run, so this case is pinned to the observed form, not a plausible one.
test_qwen_teardown_removes_its_own_file_after_qwen_rewrites_it() {
  local id rec
  id=qwen-teardown-version-q7c
  rec=$(make_spawn_case teardown-version "$id")
  read_spawn_record "$rec"
  run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" >/dev/null \
    || fail "qwen spawn should succeed before teardown"
  # shellcheck disable=SC2016  # single quotes are deliberate: qwen's literal "$version" key, not an expansion
  printf '{\n  "providerMetadata": null,\n  "$version": 4\n}\n' \
    > "$WT_DIR/.qwen/settings.json"

  run_qwen_teardown "$id" --force || fail "qwen teardown failed"
  assert_absent "$WT_DIR/.qwen/settings.json" \
    "firstmate's own workspace settings survived teardown after qwen stamped its version"
  pass "fm-teardown: firstmate's own workspace settings are removed even after qwen rewrites them"
}

# The ownership predicate decides whether teardown deletes a file it did not
# necessarily write, so it is worth testing directly across the whole shape
# space rather than only through the one form an end-to-end run happens to
# produce. Extracting it also pins its name and top-level definition.
test_qwen_settings_ownership_matrix() {
  local fn="$TMP_ROOT/qwen-ownership-fn.sh" probe="$TMP_ROOT/qwen-ownership.json" payload
  sed -n '/^qwen_workspace_settings_is_firstmate_owned()/,/^}/p' "$TEARDOWN" > "$fn"
  [ -s "$fn" ] || fail "could not extract qwen_workspace_settings_is_firstmate_owned from $TEARDOWN"
  # shellcheck source=/dev/null
  . "$fn"

  # Firstmate's own file, in every form qwen may leave it in.
  # shellcheck disable=SC2016  # single quotes are deliberate: qwen's literal "$version" key, not an expansion
  for payload in \
    '{"providerMetadata": null}' \
    '{
  "providerMetadata": null,
  "$version": 4
}' \
    '{"providerMetadata": null, "$version": "0.21.5"}' \
    '{"providerMetadata": null, "$version": true}' \
    '{"providerMetadata": null, "$version": null}' \
    '{"$version": 4, "providerMetadata": null}'; do
    printf '%s' "$payload" > "$probe"
    qwen_workspace_settings_is_firstmate_owned "$probe" \
      || fail "firstmate's own settings file was not recognized as owned: $payload"
  done

  # Anything else belongs to the project or the crewmate and must survive.
  # shellcheck disable=SC2016  # single quotes are deliberate: qwen's literal "$version" key, not an expansion
  for payload in \
    '{"ui":{"theme":"project-owned"}}' \
    '{"providerMetadata": null, "ui": {"theme":"x"}}' \
    '{"providerMetadata": {"token-plan":{"version":"abc"}}}' \
    '{"providerMetadata": null, "hooks": {"Stop": []}}' \
    '{"providerMetadata": null, "$version": {"a":1}}' \
    '{"providerMetadata": null, "$version": [1,2]}' \
    'not json at all' \
    ''; do
    printf '%s' "$payload" > "$probe"
    if qwen_workspace_settings_is_firstmate_owned "$probe"; then
      fail "a file firstmate did not write was claimed as owned and would be deleted: $payload"
    fi
  done
  pass "fm-teardown: settings ownership accepts every form of firstmate's own file and no other"
}

# The tolerance the dirty check grants must stay pinned to the one file firstmate
# writes; uncommitted work a crewmate left elsewhere under .qwen/ must still refuse.
test_qwen_dirty_check_tolerance_is_only_the_settings_file() {
  assert_source_line "  dirty=\$(printf '%s\\n' \"\$dirty_raw\" | grep -vE '^\\?\\? (\\.claude/|\\.qwen/settings\\.json\$|\\.fm-(grok|kimi|qwen)-turnend\$)' | head -1 || true)" \
    "$TEARDOWN"
  pass "fm-teardown: the untracked dirty-check tolerance names only .qwen/settings.json"
}

test_qwen_teardown_removes_every_task_artifact() {
  local id rec token
  id=qwen-teardown-q7
  rec=$(make_spawn_case teardown "$id")
  read_spawn_record "$rec"
  run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" >/dev/null \
    || fail "qwen spawn should succeed before teardown"
  token=$(sed -n 's/^token=//p' "$WT_DIR/.fm-qwen-turnend")

  run_qwen_teardown "$id" --force || fail "qwen teardown failed"
  assert_absent "$WT_DIR/.fm-qwen-turnend" "qwen token pointer survived teardown"
  assert_absent "$WT_DIR/.qwen/settings.json" "qwen workspace settings survived teardown"
  assert_absent "$HOME_DIR/.qwen/fm-turn-end.d/$token" "qwen registry token survived teardown"
  assert_absent "$HOME_DIR/state/$id.qwen-turnend-token" "qwen token state survived teardown"
  pass "fm-teardown: every qwen task artifact is removed"
}

test_qwen_busy_signature_is_the_mid_turn_cancel_hint() {
  local capture
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-tmux-lib.sh"
  unset FM_BUSY_REGEX
  capture="$TMP_ROOT/qwen-busy-pane"
  # shellcheck disable=SC2329 # Runtime override called by the sourced tmux lib.
  tmux() {
    case "${1:-}" in
      capture-pane) cat "$capture" ;;
      *) return 0 ;;
    esac
  }
  printf '  .. Counting electrons... (34s \xc2\xb7 \xe2\x86\x91 909 tokens \xc2\xb7 esc to cancel)\n' > "$capture"
  fm_pane_is_busy fake qwen || fail "qwen's mid-turn footer was not recognized as busy"
  # The idle footer names other keys and must never read as busy.
  printf '  Enter to steer \xc2\xb7 Ctrl+Q to queue \xc2\xb7 YOLO mode (shift + tab to cycle)\n' > "$capture"
  if fm_pane_is_busy fake qwen; then
    fail "qwen's idle footer was misread as busy"
  fi
  # The startup prompt's own "Remind me later (esc)" line is not a busy signal.
  printf '  3. Remind me later (esc)\n' > "$capture"
  if fm_pane_is_busy fake qwen; then
    fail "qwen's startup prompt was misread as a running turn"
  fi
  # Registered adapters keep their own signatures.
  printf '  .. thinking (12s \xc2\xb7 esc to cancel)\n' > "$capture"
  if fm_pane_is_busy fake codex; then
    fail "qwen's signature leaked into another harness"
  fi
  unset -f tmux
  pass "fm-tmux-lib: qwen's busy signature is its mid-turn cancel hint only"
}

test_qwen_idle_placeholder_reads_as_an_empty_composer() {
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-tmux-lib.sh"
  local idle_re
  idle_re=$(fm_tmux_idle_re_for_harness qwen)
  [ -n "$idle_re" ] || fail "qwen has no registered idle-composer placeholder"
  [ -z "$(fm_tmux_idle_re_for_harness claude)" ] \
    || fail "an existing adapter gained an idle-composer placeholder it did not have"
  [ -z "$(fm_tmux_idle_re_for_harness grok)" ] \
    || fail "an existing adapter gained an idle-composer placeholder it did not have"

  # qwen's placeholder carries no ghost styling, so only this registered pattern
  # can make an idle composer read as empty.
  [ "$(fm_composer_classify_content 0 '*   Type your message or @path/to/file' "$idle_re" insensitive)" = empty ] \
    || fail "qwen's idle placeholder did not read as an empty composer"
  [ "$(fm_composer_classify_content 0 '*   Type your message' "$idle_re" insensitive)" = empty ] \
    || fail "qwen's short idle placeholder did not read as an empty composer"
  [ "$(fm_composer_classify_content 0 '* Reply with exactly: STEER-OK' "$idle_re" insensitive)" = pending ] \
    || fail "real typed qwen input was misread as an empty composer"
  [ "$(fm_composer_classify_content 0 '* Type your message or @path/to/file and then stop' "$idle_re" insensitive)" = pending ] \
    || fail "typed text that merely starts like the placeholder was misread as empty"
  pass "fm-tmux-lib: qwen's unstyled idle placeholder reads empty without widening any other adapter"
}

test_qwen_is_a_verified_adapter_everywhere_the_set_is_asserted() {
  grep -Fq 'claude|codex|opencode|pi|pi-signed|grok|kimi|qwen' "$SPAWN" \
    || fail "fm-spawn does not accept qwen as a bare adapter name"
  grep -Fq '"kimi","qwen"' "$ROOT/bin/fm-bootstrap.sh" \
    || fail "bootstrap does not treat qwen as a verified dispatch-profile harness"
  grep -Fq 'kimi|qwen|' "$ROOT/bin/fm-session-lock-lib.sh" \
    || fail "the session lock does not recognize a qwen holder"
  grep -Fq '*qwen*' "$ROOT/bin/backends/tmux.sh" \
    || fail "the tmux backend does not classify a live qwen process as alive"
  grep -Fq "\`kimi\`, and \`qwen\`" "$ROOT/AGENTS.md" \
    || fail "AGENTS.md does not list qwen among the verified harnesses"
  grep -Fq '## qwen (VERIFIED' "$ROOT/.agents/skills/harness-adapters/SKILL.md" \
    || fail "the harness-adapters skill has no verified qwen section"
  pass "repository: qwen is registered everywhere the verified-adapter set is asserted"
}

test_qwen_detection_uses_ancestry() {
  local dir fakebin got
  dir="$TMP_ROOT/detection"
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *comm=*) printf '/opt/test/bin/qwen\n' ;;
  *args=*) printf 'qwen --yolo\n' ;;
  *ppid=*) printf '1\n' ;;
esac
exit 0
SH
  chmod +x "$fakebin/ps"
  # qwen is markerless, so ancestry only decides once the surrounding session's
  # own harness markers are out of the environment.
  got=$(env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT \
    PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-harness.sh")
  [ "$got" = qwen ] || fail "qwen ancestry resolved '$got', expected qwen"
  # A foreign marker still wins by the documented precedence rule.
  got=$(env -u PI_CODING_AGENT -u GROK_AGENT CLAUDECODE=1 \
    PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-harness.sh")
  [ "$got" = claude ] || fail "marker precedence changed for a qwen ancestry"
  pass "fm-harness: qwen is detected by process ancestry"
}

test_existing_launch_templates_are_byte_pinned
test_qwen_launch_is_verified
test_qwen_spawn_never_writes_the_captain_settings_file
test_qwen_spawn_preserves_a_project_owned_workspace_settings_file
test_qwen_startup_prompt_is_dismissed_only_when_present
test_qwen_startup_prompt_is_dismissed_when_it_arrives_late
test_qwen_startup_backstop_ignores_the_dialog_quoted_in_prose
test_qwen_spawn_fails_when_the_startup_prompt_never_clears
test_qwen_turnend_hook_requires_a_registered_workspace_token
test_qwen_teardown_removes_every_task_artifact
test_qwen_teardown_preserves_a_project_owned_workspace_settings_file
test_qwen_teardown_removes_its_own_file_after_qwen_rewrites_it
test_qwen_settings_ownership_matrix
test_qwen_dirty_check_tolerance_is_only_the_settings_file
test_qwen_busy_signature_is_the_mid_turn_cancel_hint
test_qwen_idle_placeholder_reads_as_an_empty_composer
test_qwen_is_a_verified_adapter_everywhere_the_set_is_asserted
test_qwen_detection_uses_ancestry
