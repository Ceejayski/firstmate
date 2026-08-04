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

file_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1" 2>/dev/null
  else
    stat -c %a "$1" 2>/dev/null
  fi
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
    dialogagain)
      # A first modal that clears into a healthy-looking pane and is then followed
      # by a SECOND one (a captain with more than one configured provider).
      printf '  Built-in Provider Update \xc2\xb7 Token Plan\n  1. Update all\n  2. Skip this version\n  3. Remind me later (esc)\n'
      ;;
    relapse)
      # The pane reads healthy on this poll; the second modal lands on the next.
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
        if [ "${FM_FAKE_QWEN_STICKY_DIALOG:-0}" = 1 ]; then
          # A qwen that ignores Escape: the modal stays up no matter the budget.
          :
        elif [ "$state" = dialogagain ]; then
          printf 'relapse\n' > "$FM_FAKE_QWEN_STATE"
        else
          printf 'working\n' > "$FM_FAKE_QWEN_STATE"
        fi
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
  # The per-task temp root is keyed on the task id alone, so a leftover from an
  # earlier run would decide this run's ownership checks instead of the spawn.
  rm -rf "/tmp/fm-$id"
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
  local id rec out rc launch meta excl settings
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

  # The provider-update suppression rides the launch command, so it reaches the
  # agent through the one literal the backend sends to the pane rather than through
  # an inherited shell environment a backend might not carry.
  settings=$(sed -n "s/.*QWEN_CODE_SYSTEM_SETTINGS_PATH='\{0,1\}\([^' ]*\)'\{0,1\} .*/\1/p" "$CASE_DIR/launch.log")
  [ -n "$settings" ] \
    || fail "qwen launch did not point QWEN_CODE_SYSTEM_SETTINGS_PATH at a settings file"
  assert_grep 'tasktmp=' "$meta" "qwen meta lost the per-task temp root that owns the settings file"
  case "$settings" in
    "/tmp/fm-$id"/*) : ;;
    *) fail "qwen's system settings file is not under this task's temp root: $settings" ;;
  esac
  case "$settings" in
    "$WT_DIR"/*) fail "qwen's system settings file was written inside the worktree: $settings" ;;
  esac
  [ "$(cat "$settings")" = '{"providerMetadata": null}' ] \
    || fail "qwen's system settings file does not carry the provider-update suppression"
  # /tmp is world-writable, and this file is qwen's highest-precedence config layer.
  [ "$(file_mode "$settings")" = 600 ] \
    || fail "qwen's system settings file is not owner-only: $(file_mode "$settings")"
  [ "$(file_mode "/tmp/fm-$id")" = 700 ] \
    || fail "the per-task temp root is not owner-only: $(file_mode "/tmp/fm-$id")"

  excl=$(git -C "$WT_DIR" rev-parse --git-path info/exclude)
  assert_grep '.fm-qwen-turnend' "$excl" "qwen token pointer was not excluded from the worktree"
  # info/exclude is CLONE-COMMON and nothing ever removes an entry from it, so
  # excluding qwen's ordinary workspace-config path would permanently hide a later
  # crewmate's own edits to it in every worktree of the project. Keeping the file
  # out of the worktree entirely is what makes any such entry unnecessary.
  assert_no_grep '.qwen/settings.json' "$excl" \
    "qwen spawn wrote a permanent clone-wide git exclude for a conventional project config path"
  assert_absent "$WT_DIR/.qwen" \
    "qwen spawn created a .qwen path inside the worktree, which git add -A would stage into the crewmate's commit"
  [ -z "$(git -C "$WT_DIR" status --porcelain)" ] \
    || fail "qwen spawn left the worktree dirty, which would block teardown"
  pass "fm-spawn: qwen launches interactively, unattended, and registers a guarded turn-end token"
}

# The settings file is qwen's HIGHEST-precedence config layer and it sits at a
# fully predictable path under a world-writable sticky /tmp, so whoever controls it
# controls a --yolo crewmate - a planted `hooks` or `mcpServers` entry would be
# executed. Both refusal paths must fail the spawn rather than trust the path.
test_qwen_system_settings_refuses_an_untrusted_path() {
  local id rec out rc sentinel before
  # (a) A symlink standing in for the settings file redirects firstmate's write.
  # The obvious target is the captain's own credential-bearing settings file.
  id=qwen-symlink-q8
  rec=$(make_spawn_case symlink "$id")
  read_spawn_record "$rec"
  sentinel="$CASE_DIR/captain-settings.json"
  before='{"env":{"SECRET_KEY":"do-not-touch"}}'
  printf '%s\n' "$before" > "$sentinel"
  mkdir -p "/tmp/fm-$id"
  chmod 700 "/tmp/fm-$id"
  ln -s "$sentinel" "/tmp/fm-$id/qwen-system-settings.json"
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  rc=$?
  [ "$rc" -ne 0 ] || fail "a qwen spawn followed a symlinked system-settings path and exited 0"
  assert_contains "$out" "is a symlink" \
    "the spawn failure did not name the symlinked system-settings path"
  [ "$(cat "$sentinel")" = "$before" ] \
    || fail "firstmate followed the symlink and truncated the file it points at"
  rm -rf "/tmp/fm-$id"

  # (b) A pre-created, loosely-permissioned temp root is somebody else's directory
  # to write into, even when this user owns it.
  id=qwen-tmpmode-q9
  rec=$(make_spawn_case tmpmode "$id")
  read_spawn_record "$rec"
  mkdir -p "/tmp/fm-$id"
  chmod 777 "/tmp/fm-$id"
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  rc=$?
  [ "$rc" -ne 0 ] || fail "a qwen spawn accepted a world-writable per-task temp root and exited 0"
  assert_contains "$out" "not the required owner-only 700" \
    "the spawn failure did not name the unsafe temp-root mode"
  assert_absent "/tmp/fm-$id/qwen-system-settings.json" \
    "firstmate wrote qwen's system settings into a world-writable directory"
  rm -rf "/tmp/fm-$id"
  pass "fm-spawn: qwen's system-settings path is refused unless firstmate provably owns it"
}

# The captain's provider credentials live in the same file qwen would rewrite if
# firstmate answered the provider-update prompt persistently. Firstmate answers it
# through a per-task SYSTEM settings layer instead, so that file must never change.
test_qwen_spawn_never_writes_the_captain_settings_file() {
  local id rec before after launch
  id=qwen-settings-q2
  rec=$(make_spawn_case settings "$id")
  read_spawn_record "$rec"
  before=$(cat "$HOME_DIR/.qwen/settings.json")
  run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" >/dev/null \
    || fail "qwen spawn should succeed"
  after=$(cat "$HOME_DIR/.qwen/settings.json")
  [ "$before" = "$after" ] || fail "qwen spawn modified the captain's credential-bearing settings file"
  launch=$(cat "$CASE_DIR/launch.log")
  assert_contains "$launch" "QWEN_CODE_SYSTEM_SETTINGS_PATH=" \
    "qwen spawn did not point the system settings layer at its own suppression file"
  pass "fm-spawn: qwen suppresses the startup prompt per task and never edits captain settings"
}

# A project that tracks its own .qwen/settings.json must come through a qwen spawn
# untouched AND still get the suppression - the system layer overrides the
# workspace one, so firstmate no longer has to choose between the two.
test_qwen_spawn_preserves_a_project_owned_workspace_settings_file() {
  local id rec original launch
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
  launch=$(cat "$CASE_DIR/launch.log")
  assert_contains "$launch" "QWEN_CODE_SYSTEM_SETTINGS_PATH=" \
    "a project-owned workspace settings file suppressed firstmate's own provider-update fix"
  pass "fm-spawn: a project's own workspace settings survive and still get the suppression"
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

# The modal title is per-provider (`Built-in Provider Update · <provider>`), so a
# captain with several configured providers can be shown a SECOND modal after the
# first is dismissed. A gate that stood down on the clean poll between them would
# report success and leave the crewmate wedged behind the second dialog - exactly
# the failure the gate exists to prevent - so it stays armed for the whole window.
test_qwen_startup_prompt_is_dismissed_when_a_second_modal_follows() {
  local id rec out rc escapes
  id=qwen-twodialogs-q4e
  rec=$(make_spawn_case twodialogs "$id")
  read_spawn_record "$rec"
  out=$(FM_FAKE_QWEN_AFTER_LAUNCH=dialogagain FM_QWEN_STARTUP_POLLS=6 \
    run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  rc=$?
  expect_code 0 "$rc" "qwen spawn should succeed once both startup modals are cleared"
  assert_contains "$out" "spawned $id harness=qwen" "qwen spawn did not report success"
  escapes=$(grep -c '^Escape$' "$CASE_DIR/key.log" || true)
  [ "$escapes" -ge 2 ] \
    || fail "a second provider-update modal raised after the first was cleared drew no Escape (got $escapes)"
  pass "fm-spawn: the qwen startup backstop stays armed after a dismissal and catches a second modal"
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

# fm-spawn writes no .qwen/ path in the worktree, so teardown has none to reclaim
# and must never delete one. Otherwise a project's own qwen config - or one the
# crewmate authored as its actual task - is silently destroyed.
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

# firstmate now puts nothing under .qwen/ in the worktree, so the dirty check must
# grant .qwen/ NO tolerance: anything a crewmate leaves there is the crewmate's own
# work and must still refuse the return. This runs the real filter over real git
# output rather than pinning a regex that merely reads plausible.
test_qwen_dirty_check_grants_no_qwen_tolerance() {
  local line pattern repo dirty
  line=$(grep -F "dirty=\$(printf '%s\\n' \"\$dirty_raw\" | grep -vE '" "$TEARDOWN") \
    || fail "could not read the dirty-check tolerance out of $TEARDOWN"
  pattern=${line#*grep -vE \'}
  pattern=${pattern%%\'*}
  case "$pattern" in
    *qwen/*) fail "the dirty check still tolerates a .qwen/ path firstmate no longer writes: $pattern" ;;
  esac

  repo="$TMP_ROOT/dirty-tolerance"
  fm_git_init_commit "$repo"
  mkdir -p "$repo/.qwen"
  printf '%s\n' '{"ui":{"theme":"crewmate-authored"}}' > "$repo/.qwen/settings.json"
  dirty=$(git -C "$repo" status --porcelain | grep -vE "$pattern" | head -1 || true)
  [ -n "$dirty" ] \
    || fail "teardown would silently discard a crewmate's uncommitted .qwen/ work"

  # firstmate's own per-worktree pointer is still tolerated.
  rm -rf "$repo/.qwen"
  printf 'token=fm.aaaaaaaaaaaa\n' > "$repo/.fm-qwen-turnend"
  dirty=$(git -C "$repo" status --porcelain | grep -vE "$pattern" | head -1 || true)
  [ -z "$dirty" ] \
    || fail "teardown would refuse a qwen worktree return over firstmate's own token pointer: $dirty"
  pass "fm-teardown: the dirty check tolerates firstmate's own pointer and no .qwen/ path"
}

test_qwen_teardown_removes_every_task_artifact() {
  local id rec token settings
  id=qwen-teardown-q7
  rec=$(make_spawn_case teardown "$id")
  read_spawn_record "$rec"
  run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" >/dev/null \
    || fail "qwen spawn should succeed before teardown"
  token=$(sed -n 's/^token=//p' "$WT_DIR/.fm-qwen-turnend")
  settings=$(sed -n "s/.*QWEN_CODE_SYSTEM_SETTINGS_PATH='\{0,1\}\([^' ]*\)'\{0,1\} .*/\1/p" "$CASE_DIR/launch.log")
  assert_present "$settings" "qwen spawn never wrote its system settings file"

  run_qwen_teardown "$id" --force || fail "qwen teardown failed"
  assert_absent "$WT_DIR/.fm-qwen-turnend" "qwen token pointer survived teardown"
  # The settings file lives under tasktmp, so it goes with the rest of that root.
  assert_absent "$settings" "qwen's system settings file survived teardown"
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

# A new adapter must not move the harness-AGNOSTIC busy default. That default is
# what the submit core's busy-queued-Enter fallback reads when no harness is
# recorded, and it is consulted for claude/codex/opencode/pi panes too. qwen's
# `esc to cancel` appears verbatim in this repo's own tracked files, so putting it
# there would make a crewmate on another harness rendering one of them read as
# busy - and a genuinely swallowed Enter would then be reported as delivered.
test_shared_busy_default_is_unchanged_by_the_qwen_adapter() {
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-tmux-lib.sh"
  unset FM_BUSY_REGEX
  [ "$FM_TMUX_BUSY_REGEX_DEFAULT" = 'esc (to )?interrupt|Working\.\.\.|Ctrl\+c:cancel' ] \
    || fail "the harness-agnostic busy default gained or lost a token: $FM_TMUX_BUSY_REGEX_DEFAULT"
  [ "$FM_TMUX_QWEN_BUSY_REGEX_DEFAULT" = 'esc to cancel' ] \
    || fail "qwen lost its own busy signature: $FM_TMUX_QWEN_BUSY_REGEX_DEFAULT"
  if printf '  .. Counting electrons... (34s \xc2\xb7 esc to cancel)\n' \
     | grep -qiE "$FM_TMUX_BUSY_REGEX_DEFAULT"; then
    fail "qwen's busy token leaked into the harness-agnostic default"
  fi
  # fm-watch mirrors the same shared default and must not drift from it.
  assert_source_line "BUSY_REGEX=\${FM_BUSY_REGEX:-'esc (to )?interrupt|Working\\.\\.\\.|Ctrl\\+c:cancel'}" \
    "$ROOT/bin/fm-watch.sh" "fm-watch's mirror of the shared busy default drifted"
  pass "fm-tmux-lib: the harness-agnostic busy default is untouched by the qwen adapter"
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
test_qwen_system_settings_refuses_an_untrusted_path
test_qwen_spawn_preserves_a_project_owned_workspace_settings_file
test_qwen_startup_prompt_is_dismissed_only_when_present
test_qwen_startup_prompt_is_dismissed_when_it_arrives_late
test_qwen_startup_prompt_is_dismissed_when_a_second_modal_follows
test_qwen_startup_backstop_ignores_the_dialog_quoted_in_prose
test_qwen_spawn_fails_when_the_startup_prompt_never_clears
test_qwen_turnend_hook_requires_a_registered_workspace_token
test_qwen_teardown_removes_every_task_artifact
test_qwen_teardown_preserves_a_project_owned_workspace_settings_file
test_qwen_dirty_check_grants_no_qwen_tolerance
test_qwen_busy_signature_is_the_mid_turn_cancel_hint
test_shared_busy_default_is_unchanged_by_the_qwen_adapter
test_qwen_idle_placeholder_reads_as_an_empty_composer
test_qwen_is_a_verified_adapter_everywhere_the_set_is_asserted
test_qwen_detection_uses_ancestry
