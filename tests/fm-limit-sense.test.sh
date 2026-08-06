#!/usr/bin/env bash
# Behavior tests for bin/fm-limit-sense.sh - the transcript-based limit-death
# sensor - and for its three consumers (crew-state detail, session-start digest
# line, watcher heartbeat annotation).
#
# Every classification case runs against a REAL CAPTURED transcript row under
# tests/fixtures/limit-sense/. The `message` object, `timestamp`, `error`,
# `apiErrorStatus` and `isApiErrorMessage` of each synthetic row are verbatim
# from a live Claude Code session; only identity/path fields and the free text
# of surrounding non-synthetic rows were replaced. Synthesizing these rows by
# hand would defeat the point: the whole design rests on the claim that the real
# rows are structurally distinguishable.
#
# Cases:
#   (a) THE critical regression: `No response requested.` -> none, never dead.
#       It is the most common synthetic message on the fleet, so a bare
#       model=="<synthetic>" check would report healthy workers as dead - the one
#       way this sensor could be worse than no sensor at all.
#   (b) session limit / weekly limit / out of credits -> dead, class=limit
#   (c) both reset forms parse to an absolute UTC instant
#   (d) 529 -> class=transient; /login 403 -> class=auth
#   (d2) a row whose TEXT this version does not recognize is still classified by
#       its own error/apiErrorStatus/isApiErrorMessage fields
#   (e) real activity after the death -> recovered
#   (f) a clean session -> none
#   (g) non-claude harness, missing transcript, missing meta, missing jq ->
#       unknown, ALWAYS exit 0 (a sensor must never break its caller)
#   (h) nothing is written outside state/ and nothing is sent to any agent
#   (i) fm-crew-state.sh carries a distinguishable limit-dead detail
#   (j) fm-session-start.sh's fleet digest carries a per-task quota line
#   (k) fm-watch.sh's heartbeat annotation names limit-dead tasks
#   (l) the report's §3.3 live-worktree result reproduces (opt-in; skipped when
#       those transcripts are not on this machine)
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SENSE="$ROOT/bin/fm-limit-sense.sh"
FIXTURES="$ROOT/tests/fixtures/limit-sense"
TMP_ROOT=$(fm_test_tmproot fm-limit-sense)

HOME_DIR="$TMP_ROOT/home"
STATE_DIR="$HOME_DIR/state"
PROJECTS_DIR="$TMP_ROOT/claude-projects"
WT_ROOT="$TMP_ROOT/wt"
mkdir -p "$STATE_DIR" "$PROJECTS_DIR" "$WT_ROOT"

export FM_STATE_OVERRIDE="$STATE_DIR"
export FM_CLAUDE_PROJECTS_DIR="$PROJECTS_DIR"

# Verified against all 155 transcript directories on the capture machine: the
# slug is the absolute cwd with '/', '.' and '_' each replaced by '-'.
slug_of() {  # <abs-path>
  printf '%s' "$1" | tr '/._' '---'
}

# install_task <id> <fixture-or-none> [harness] [kind] -> echoes the worktree
install_task() {
  local id=$1 fixture=$2 harness=${3:-claude} kind=${4:-ship} wt dir
  wt="$WT_ROOT/$id"
  mkdir -p "$wt"
  if [ "$fixture" != none ]; then
    dir="$PROJECTS_DIR/$(slug_of "$wt")"
    mkdir -p "$dir"
    cp "$FIXTURES/$fixture"/*.jsonl "$dir/"
  fi
  fm_write_meta "$STATE_DIR/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$wt" \
    "harness=$harness" \
    "kind=$kind"
  printf '%s\n' "$wt"
}

# sense <id> [args...] - run the sensor, fail if it ever exits non-zero.
sense() {
  local id=$1 out code
  shift
  out=$("$SENSE" "$id" --no-pipeline "$@" 2>/dev/null)
  code=$?
  expect_code 0 "$code" "fm-limit-sense must never fail its caller (id=$id)"
  printf '%s' "$out"
}

# --- (a) THE critical regression -------------------------------------------

install_task benign no-response-requested >/dev/null
OUT=$(sense benign)
assert_contains "$OUT" "limit: none" \
  "'No response requested.' must report none - the most common synthetic message"
assert_not_contains "$OUT" "dead" \
  "'No response requested.' must NEVER report dead (bare synthetic check regression)"
# Prove the fixture really is a synthetic row, so this case cannot silently
# degrade into "the file had no synthetic row at all".
assert_grep '"<synthetic>"' "$PROJECTS_DIR/$(slug_of "$WT_ROOT/benign")/fixture-session.jsonl" \
  "the benign fixture must actually contain a model==<synthetic> row"
pass "critical regression: 'No response requested.' -> none, never dead"

# --- (b) + (c) limit deaths and reset parsing ------------------------------

install_task session-limit session-limit >/dev/null
OUT=$(sense session-limit)
assert_contains "$OUT" "limit: dead" "session limit must report dead"
assert_contains "$OUT" "class=limit" "session limit must classify as limit"
assert_contains "$OUT" "since=2026-07-30T00:50:41Z" "session limit must report the death instant"
# 'resets 2:30am (Africa/Lagos)' after a 00:50:41Z death: 02:30 Lagos (UTC+1)
# on the same local day is 01:30Z.
assert_contains "$OUT" "reset=2026-07-30T01:30:00Z" \
  "the <h>:<mm><am|pm> reset form must parse to an absolute UTC instant"
assert_contains "$OUT" "harness=claude" "the adapter must be named"
pass "session limit -> dead, class=limit, absolute reset"

install_task weekly-limit weekly-limit >/dev/null
OUT=$(sense weekly-limit)
assert_contains "$OUT" "limit: dead" "weekly limit must report dead"
assert_contains "$OUT" "class=limit" "weekly limit must classify as limit"
# 'resets Aug 3 at 3pm (Africa/Lagos)' -> 15:00 Lagos = 14:00Z.
assert_contains "$OUT" "reset=2026-08-03T14:00:00Z" \
  "the <Mon> <d> at <h><am|pm> reset form must parse to an absolute UTC instant"
pass "weekly limit -> dead with the dated reset form parsed"

install_task credits out-of-credits >/dev/null
OUT=$(sense credits)
assert_contains "$OUT" "limit: dead" "out of usage credits must report dead"
assert_contains "$OUT" "class=limit" "out of usage credits must classify as limit"
# This message carries no reset time at all; the field must simply be absent
# rather than guessed.
assert_not_contains "$OUT" "reset=" "a message with no reset time must not invent one"
pass "out of usage credits -> dead, class=limit, no invented reset"

# --- (d) transient and auth ------------------------------------------------

install_task overloaded overloaded-529 >/dev/null
OUT=$(sense overloaded)
assert_contains "$OUT" "limit: dead" "a 529 that ended the turn must report dead"
assert_contains "$OUT" "class=transient" "a 529 must classify as transient, not limit"
assert_not_contains "$OUT" "reset=" "a transient death has no quota reset"
pass "529 -> dead, class=transient"

install_task login login-403 >/dev/null
OUT=$(sense login)
assert_contains "$OUT" "limit: dead" "a login prompt that ended the turn must report dead"
assert_contains "$OUT" "class=auth" \
  "a /login 403 must classify as auth - it needs a human and must never auto-resume"
pass "login 403 -> dead, class=auth"

# --- (d2) structural corroboration for an unrecognized message -------------
#
# These rows are DELIBERATELY synthesized rather than captured, and are the one
# exception to the real-rows rule above: an unrecognized text cannot by
# definition be one of the captured messages, and this branch - the hardening
# that keeps a drifted message family classifiable across CLI versions - is
# otherwise never exercised at all. Their field SHAPE is still the captured one.
#
# install_drifted <id> <row-json> - a lone synthetic assistant row.
install_drifted() {
  local id=$1 row=$2 wt dir
  wt="$WT_ROOT/$id"
  dir="$PROJECTS_DIR/$(slug_of "$wt")"
  mkdir -p "$wt" "$dir"
  printf '%s\n' "$row" > "$dir/fixture-session.jsonl"
  fm_write_meta "$STATE_DIR/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$wt" \
    "harness=claude" \
    "kind=ship"
}

# No `.error` at all: the fields after it are empty, which is exactly the case a
# tab-separated read collapses and shifts left.
install_drifted drift-429 '{"type":"assistant","timestamp":"2026-08-01T09:12:00Z","apiErrorStatus":429,"isApiErrorMessage":true,"message":{"model":"<synthetic>","content":[{"type":"text","text":"Quota exhausted for this workspace; see the console for details."}]}}'
OUT=$(sense drift-429)
assert_contains "$OUT" "limit: dead" "an unrecognized 429 row must still report dead"
assert_contains "$OUT" "class=limit" \
  "apiErrorStatus 429 must classify an unrecognized message as limit"
# Also proves the fields did not shift: the timestamp is field two.
assert_contains "$OUT" "since=2026-08-01T09:12:00Z" \
  "a timestamp with no fractional seconds must not gain a second Z"
assert_not_contains "$OUT" "ZZ" "the death instant must be a single well-formed UTC stamp"
assert_not_contains "$OUT" "reset=" "a message with no reset text must not invent one"
pass "unrecognized text + 429 -> dead, class=limit"

install_drifted drift-401 '{"type":"assistant","timestamp":"2026-08-01T09:13:00.250Z","apiErrorStatus":401,"isApiErrorMessage":true,"message":{"model":"<synthetic>","content":[{"type":"text","text":"Your credentials could not be verified for this workspace."}]}}'
OUT=$(sense drift-401)
assert_contains "$OUT" "class=auth" "apiErrorStatus 401 must classify as auth"
assert_contains "$OUT" "since=2026-08-01T09:13:00Z" "fractional seconds are dropped, not the Z"
pass "unrecognized text + 401 -> class=auth"

install_drifted drift-503 '{"type":"assistant","timestamp":"2026-08-01T09:14:00.100Z","apiErrorStatus":503,"isApiErrorMessage":true,"message":{"model":"<synthetic>","content":[{"type":"text","text":"The upstream service did not answer in time."}]}}'
OUT=$(sense drift-503)
assert_contains "$OUT" "class=transient" "a 5xx must classify as transient, never as limit"
pass "unrecognized text + 5xx -> class=transient"

# Not an API error at all: a harness meta message this version does not know by
# name is still benign, and benign must never read as dead.
install_drifted drift-benign '{"type":"assistant","timestamp":"2026-08-01T09:15:00.000Z","isApiErrorMessage":false,"message":{"model":"<synthetic>","content":[{"type":"text","text":"Continuing from a previous conversation."}]}}'
OUT=$(sense drift-benign)
assert_contains "$OUT" "limit: none" \
  "a synthetic row that is not an API error must report none, never dead"
assert_not_contains "$OUT" "dead" "a non-error synthetic row must never report dead"
pass "unrecognized text + no API error -> none"

# An error with nothing that names it stays honestly unknown.
install_drifted drift-opaque '{"type":"assistant","timestamp":"2026-08-01T09:16:00.000Z","isApiErrorMessage":true,"message":{"model":"<synthetic>","content":[{"type":"text","text":"Something went wrong."}]}}'
OUT=$(sense drift-opaque)
assert_contains "$OUT" "limit: unknown" "an unclassifiable error row must report unknown"
assert_not_contains "$OUT" "class=" "the sensor must not name a class it did not establish"
pass "unrecognized text + unnamed error -> unknown"

# --- (e) recovery ----------------------------------------------------------

install_task recovered recovered-session-limit >/dev/null
OUT=$(sense recovered)
assert_contains "$OUT" "limit: recovered" \
  "real non-synthetic activity after the death must report recovered"
assert_contains "$OUT" "class=limit" "a recovered task still names what killed it"
assert_contains "$OUT" "since=2026-07-31T22:15:30Z" "a recovered task still reports the death instant"
pass "activity after the death -> recovered"

# --- (f) clean session -----------------------------------------------------

install_task clean clean-session >/dev/null
OUT=$(sense clean)
assert_contains "$OUT" "limit: none" "a transcript with no synthetic row is a clean session"
assert_not_contains "$OUT" "class=" "a clean session has nothing to classify"
pass "clean session -> none"

# --- (g) unknown paths, always exit 0 --------------------------------------

install_task codex-task session-limit codex >/dev/null
OUT=$(sense codex-task)
assert_contains "$OUT" "limit: unknown" \
  "a non-claude harness must report unknown - coverage is a per-harness adapter"
assert_contains "$OUT" "harness=codex" "the unrecognized adapter must be named"
assert_not_contains "$OUT" "dead" "a non-claude task must never be reported dead"
pass "non-claude harness -> unknown, exit 0"

for h in grok opencode pi kimi qwen; do
  install_task "harness-$h" session-limit "$h" >/dev/null
  OUT=$(sense "harness-$h")
  assert_contains "$OUT" "limit: unknown" "harness $h must report unknown"
done
pass "every unverified harness adapter -> unknown, exit 0"

install_task no-transcript none >/dev/null
OUT=$(sense no-transcript)
assert_contains "$OUT" "limit: unknown" "a missing transcript directory must report unknown"
pass "missing transcript directory -> unknown, exit 0"

OUT=$(sense definitely-no-such-task)
assert_contains "$OUT" "limit: unknown" "a missing meta file must report unknown"
pass "missing metadata -> unknown, exit 0"

# An empty transcript directory (session dir created, no rows yet).
WT=$(install_task empty-dir none)
mkdir -p "$PROJECTS_DIR/$(slug_of "$WT")"
OUT=$(sense empty-dir)
assert_contains "$OUT" "limit: unknown" "an empty transcript directory must report unknown"
pass "empty transcript directory -> unknown, exit 0"

# A truncated / non-JSON transcript must degrade, not explode.
WT=$(install_task corrupt none)
mkdir -p "$PROJECTS_DIR/$(slug_of "$WT")"
printf '{"model":"<synthetic>" this is not json\n' > "$PROJECTS_DIR/$(slug_of "$WT")/fixture-session.jsonl"
OUT=$(sense corrupt)
assert_contains "$OUT" "limit: unknown" "an unparseable transcript must report unknown"
pass "unparseable transcript -> unknown, exit 0"

# Without jq the sensor has no parser, so it must say so rather than guess.
# A minimal PATH carrying everything the script needs EXCEPT jq, so this
# exercises the real absent-jq branch rather than a broken-jq one.
NOJQ_BIN="$TMP_ROOT/nojq-bin"
mkdir -p "$NOJQ_BIN"
for t in bash sh env grep sed tr cut tail basename dirname node uname; do
  real=$(command -v "$t" 2>/dev/null) || continue
  ln -sf "$real" "$NOJQ_BIN/$t"
done
command -v jq >/dev/null 2>&1 && [ ! -e "$NOJQ_BIN/jq" ] || fail "the no-jq PATH must not carry jq"
OUT=$(PATH="$NOJQ_BIN" "$SENSE" session-limit --no-pipeline 2>/dev/null)
CODE=$?
expect_code 0 "$CODE" "a missing jq must still exit 0"
assert_contains "$OUT" "limit: unknown" "a missing parser must report unknown, never guess"
pass "missing parser -> unknown, exit 0"

# A jq that is present but broken must degrade the same way.
BROKEN_BIN="$TMP_ROOT/broken-jq-bin"
mkdir -p "$BROKEN_BIN"
cat > "$BROKEN_BIN/jq" <<'SH'
#!/usr/bin/env bash
exit 127
SH
chmod +x "$BROKEN_BIN/jq"
OUT=$(PATH="$BROKEN_BIN:$PATH" "$SENSE" session-limit --no-pipeline 2>/dev/null)
CODE=$?
expect_code 0 "$CODE" "a broken jq must still exit 0"
assert_contains "$OUT" "limit: unknown" "a broken parser must report unknown, never guess"
pass "broken parser -> unknown, exit 0"

# Usage errors are the ONLY non-zero exit.
"$SENSE" >/dev/null 2>&1 && fail "no task id must be a usage error"
expect_code 2 "$?" "no task id"
pass "usage error is the only non-zero exit"

# --- (h) read-only, and it sends nothing -----------------------------------

BEFORE=$(find "$TMP_ROOT" -type f | LC_ALL=C sort)
sense session-limit >/dev/null
sense recovered >/dev/null
AFTER=$(find "$TMP_ROOT" -type f | LC_ALL=C sort)
[ "$BEFORE" = "$AFTER" ] || fail "the sensor must not create or remove any file"
pass "detection only: no file created or removed anywhere"

# Prove it by construction too: no send/spawn/resume path may exist in the
# script. This ship is explicitly detection only - auto-resume is a separate,
# captain-held decision.
for forbidden in fm-send.sh fm-spawn.sh tmux send-keys 'axi respond'; do
  assert_no_grep "$forbidden" "$SENSE" \
    "fm-limit-sense must not reference '$forbidden' - it sends nothing to any agent"
done
# The stranded-custody read must never use the bare command, which moves HEAD.
grep -n 'axi sync' "$SENSE" | grep -v -- '--check' | grep -q . \
  && fail "every 'axi sync' call must carry --check"
pass "no agent is sent anything; every pipeline read is --check only"

# --- (h2) stranded validation custody --------------------------------------

# A run killed mid-validation leaves its commits in the local gate. The sensor
# asks `axi sync --check` (read-only) and reports the custody answer. Driven by
# a fake no-mistakes that serves the real TOON shape, so both the parse and the
# --check-only guarantee are covered rather than assumed.
NM_BIN="$TMP_ROOT/nm-bin"
mkdir -p "$NM_BIN"
NM_CALLS="$TMP_ROOT/nm-calls"
cat > "$NM_BIN/no-mistakes" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$NM_CALLS"
cat <<'TOON'
branch_sync:
  state: stranded_terminal_run
  next_action:
    code: recover_custody
    note: unpublished pipeline commits are held by a terminal run
TOON
SH
chmod +x "$NM_BIN/no-mistakes"

: > "$NM_CALLS"
OUT=$(PATH="$NM_BIN:$PATH" "$SENSE" session-limit 2>/dev/null)
expect_code 0 "$?" "the custody check must not change the exit status"
assert_contains "$OUT" "limit: dead" "the custody check must not change the verdict"
assert_contains "$OUT" "pipeline=recover-custody" \
  "a stranded validation must be surfaced on the limit-dead line"
assert_grep "axi sync --check" "$NM_CALLS" "the custody read must go through axi sync --check"
assert_no_grep "--recover" "$NM_CALLS" "the sensor must never return custody itself"
grep -v -- '--check' "$NM_CALLS" | grep -q 'axi sync' \
  && fail "every axi sync invocation must carry --check"
pass "stranded validation -> pipeline=recover-custody via a read-only --check"

# A healthy branch answers no custody question, so the field stays absent.
cat > "$NM_BIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
printf 'branch_sync:\n  state: in_sync\n  next_action:\n    code: none\n'
SH
chmod +x "$NM_BIN/no-mistakes"
OUT=$(PATH="$NM_BIN:$PATH" "$SENSE" session-limit 2>/dev/null)
assert_not_contains "$OUT" "pipeline=" "a branch in sync must not claim stranded custody"
pass "no stranded validation -> no pipeline field"

# --no-pipeline must not shell out at all, and a recovered task must not pay
# for the check unless it is explicitly asked for.
cat > "$NM_BIN/no-mistakes" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$NM_CALLS"
printf 'branch_sync:\n  next_action:\n    code: recover_custody\n'
SH
chmod +x "$NM_BIN/no-mistakes"
: > "$NM_CALLS"
PATH="$NM_BIN:$PATH" "$SENSE" session-limit --no-pipeline >/dev/null 2>&1
[ -s "$NM_CALLS" ] && fail "--no-pipeline must not run any no-mistakes subprocess"
PATH="$NM_BIN:$PATH" "$SENSE" recovered >/dev/null 2>&1
[ -s "$NM_CALLS" ] && fail "a recovered task must not pay for the custody check by default"
OUT=$(PATH="$NM_BIN:$PATH" "$SENSE" recovered --pipeline 2>/dev/null)
assert_contains "$OUT" "pipeline=recover-custody" \
  "--pipeline must ask the custody question for a recovered task too"
pass "custody check runs only where it is wanted"

# --- (i) fm-crew-state.sh detail -------------------------------------------

CREW_STATE="$ROOT/bin/fm-crew-state.sh"
# A dead crew with a torn-down endpoint: the state read has no source at all,
# which is exactly the line a supervisor sees today for a limit-killed worker.
OUT=$(FM_CREW_STATE_NM_TIMEOUT=1 "$CREW_STATE" session-limit 2>/dev/null)
CODE=$?
expect_code 0 "$CODE" "fm-crew-state must still exit 0"
assert_contains "$OUT" "limit-dead" \
  "fm-crew-state must carry a distinguishable limit-dead detail"
assert_contains "$OUT" "class=limit" "the crew-state detail must carry the class"
pass "fm-crew-state.sh: limit-dead is a distinguishable detail"

OUT=$(FM_CREW_STATE_NM_TIMEOUT=1 "$CREW_STATE" benign 2>/dev/null)
assert_not_contains "$OUT" "limit-dead" \
  "a benign synthetic row must not annotate fm-crew-state as limit-dead"
OUT=$(FM_CREW_STATE_NM_TIMEOUT=1 "$CREW_STATE" recovered 2>/dev/null)
assert_not_contains "$OUT" "limit-dead" \
  "a recovered crew is the steady state and must not be annotated"
OUT=$(FM_CREW_STATE_NM_TIMEOUT=1 "$CREW_STATE" codex-task 2>/dev/null)
assert_not_contains "$OUT" "limit-dead" "an unknown verdict must not annotate"
pass "fm-crew-state.sh: only a dead verdict annotates"

OUT=$(FM_CREW_STATE_LIMIT_SENSE=0 FM_CREW_STATE_NM_TIMEOUT=1 "$CREW_STATE" session-limit 2>/dev/null)
assert_not_contains "$OUT" "limit-dead" "FM_CREW_STATE_LIMIT_SENSE=0 must disable the annotation"
pass "fm-crew-state.sh: the annotation has an off switch"

# --- (j) session-start fleet digest ----------------------------------------

# The digest loop is what is under test, not the lock or the sweeps, so run the
# script in detect-only mode with the lock deliberately unavailable and read the
# fleet section it always prints.
DIGEST=$(cd "$HOME_DIR" && FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$STATE_DIR" FM_CLAUDE_PROJECTS_DIR="$PROJECTS_DIR" \
  FM_BOOTSTRAP_DETECT_ONLY=1 "$ROOT/bin/fm-session-start.sh" 2>/dev/null || true)
assert_contains "$DIGEST" "quota: limit: dead" \
  "the fleet digest must carry a per-task quota line naming a limit death"
assert_contains "$DIGEST" "quota: limit: none" \
  "the fleet digest must report healthy tasks too, so silence is never ambiguous"
assert_contains "$DIGEST" "quota: limit: unknown" \
  "the fleet digest must say unknown for an unverified adapter"
pass "fm-session-start.sh: the fleet digest carries a per-task quota line"

# The stranded-validation check costs a subprocess per limit-dead task, and the
# failure it exists for is common mode: one limit kills the whole fleet, so
# "dead tasks" is routinely "every task". The budget must bound that, and a
# spent budget must be reported rather than silently truncated.
DIGEST0=$(cd "$HOME_DIR" && FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$STATE_DIR" FM_CLAUDE_PROJECTS_DIR="$PROJECTS_DIR" \
  FM_SESSION_START_CUSTODY_BUDGET=0 FM_BOOTSTRAP_DETECT_ONLY=1 \
  "$ROOT/bin/fm-session-start.sh" 2>/dev/null || true)
assert_contains "$DIGEST0" "pipeline=not-checked" \
  "a deferred custody check must say so on the task's own line"
assert_contains "$DIGEST0" "stranded-validation check deferred" \
  "a spent budget must be reported, never silently truncated"
assert_contains "$DIGEST0" "fm-limit-sense.sh --pipeline" \
  "the deferral note must name the command that answers the deferred question"
pass "fm-session-start.sh: the custody-check budget is bounded and never silent"

# --- (k) watcher heartbeat annotation --------------------------------------

# Exercise the real function from the real script rather than re-implementing
# it: source fm-watch.sh's annotation body in isolation.
ANNOTATE=$(awk '/^heartbeat_limit_annotation\(\) \{$/,/^\}$/' "$ROOT/bin/fm-watch.sh")
[ -n "$ANNOTATE" ] || fail "bin/fm-watch.sh must define heartbeat_limit_annotation"
OUT=$(
  # Consumed by the evaluated fm-watch.sh function body, not by this shell.
  # shellcheck disable=SC2034
  SCRIPT_DIR="$ROOT/bin"
  # shellcheck disable=SC2034
  STATE="$STATE_DIR"
  eval "$ANNOTATE"
  heartbeat_limit_annotation
)
assert_contains "$OUT" "limit-dead=" "the heartbeat annotation must name limit-dead tasks"
assert_contains "$OUT" "session-limit" "the heartbeat annotation must list the dead task id"
assert_not_contains "$OUT" "recovered" "a recovered task is not annotated as dead"
assert_not_contains "$OUT" "benign" "a benign synthetic row is not annotated as dead"
pass "fm-watch.sh: the heartbeat payload names limit-dead tasks"

EMPTY_STATE="$TMP_ROOT/empty-state"
mkdir -p "$EMPTY_STATE"
OUT=$(
  # shellcheck disable=SC2034
  SCRIPT_DIR="$ROOT/bin"
  # shellcheck disable=SC2034
  STATE="$EMPTY_STATE"
  eval "$ANNOTATE"
  heartbeat_limit_annotation
)
[ -z "$OUT" ] || fail "a fleet with no limit death must add no heartbeat annotation"
pass "fm-watch.sh: a healthy fleet adds no annotation"

# The annotation must be annotation ONLY - it must not gate whether the
# heartbeat fires. Both firing call sites carry it; the absorbed path does not.
# The pattern is a literal source line, so it must not expand here.
# shellcheck disable=SC2016
FIRING=$(grep -c 'fm_wake_append heartbeat heartbeat "heartbeat\$(heartbeat_limit_annotation)"' \
  "$ROOT/bin/fm-watch.sh" || true)
[ "$FIRING" = 2 ] || fail "both firing heartbeat call sites must carry the annotation (got $FIRING)"
grep -n 'heartbeat_limit_annotation' "$ROOT/bin/fm-watch.sh" \
  | grep -q 'heartbeat_scan_finds_actionable' \
  && fail "the annotation must not decide whether a heartbeat fires"
pass "fm-watch.sh: annotation only, never a new firing condition"

# --- (l) the report's §3.3 live-worktree reproduction ----------------------
#
# Opt-in and machine-specific: it reads the real ~/.claude transcripts the
# investigation measured. Skipped cleanly anywhere those are absent, so CI stays
# hermetic while the claim stays checkable where the evidence lives.
#
# What is asserted is only what is DURABLE. §3.3's per-worktree verdicts are
# not: transcripts keep growing, and the fleet has taken further limit deaths
# since - including one that hit this repo's own worktree, the report's negative
# control, mid-implementation. The durable claim, and the only one this case
# enforces, is that the real end-to-end path over the real ~/.claude directories
# returns a valid verdict for every live worktree and never fails its caller.
# A recorded death that is STILL the newest death in its transcript is checked
# byte-exactly on top of that, but its absence is not a failure: any new session
# in one of these worktrees permanently retires that recording, so requiring one
# would make the suite fail on its own over time. Byte-exact reproduction
# belongs to the committed fixtures under tests/fixtures/limit-sense/, which are
# real captured rows and hermetic; when no recording survives here, this case
# reports a skip - and a skip is not coverage.
LIVE_STATE="$TMP_ROOT/live-state"
mkdir -p "$LIVE_STATE"
LIVE_RUN=0
LIVE_EXACT=0
i=0
# worktree<TAB>the death instant §3.3 recorded for it, or '-' for the control
while IFS=$(printf '\t') read -r wt want; do
  [ -n "$wt" ] || continue
  [ -d "$HOME/.claude/projects/$(slug_of "$wt")" ] || continue
  i=$((i + 1))
  fm_write_meta "$LIVE_STATE/live-$i.meta" "worktree=$wt" "harness=claude" "kind=ship"
  OUT=$(FM_STATE_OVERRIDE="$LIVE_STATE" FM_CLAUDE_PROJECTS_DIR="$HOME/.claude/projects" \
    "$SENSE" "live-$i" --no-pipeline 2>/dev/null)
  expect_code 0 "$?" "the live read must exit 0 for $wt"
  LIVE_RUN=$((LIVE_RUN + 1))
  case "$OUT" in
    "limit: none"*|"limit: dead"*|"limit: recovered"*|"limit: unknown"*) ;;
    *) fail "live worktree $wt returned an unparseable verdict: $OUT" ;;
  esac
  # A recorded death still reproduces byte-exactly whenever no newer session has
  # become the newest transcript in that directory.
  case "$want:$OUT" in
    -:*) ;;
    *"since=$want"*)
      assert_contains "$OUT" "class=limit" "the recorded §3.3 death at $want must classify as limit"
      assert_contains "$OUT" "reset=2026-08-05T08:10:00Z" \
        "the recorded §3.3 death at $want must resolve the 9:10am Lagos reset to 08:10Z"
      LIVE_EXACT=$((LIVE_EXACT + 1))
      ;;
  esac
done <<LIVE
$HOME/.treehouse/my-repo-e48f68/5/my-repo	2026-08-05T07:14:20Z
$HOME/.treehouse/my-repo-e48f68/7/my-repo	2026-08-05T06:33:14Z
$HOME/.treehouse/my-repo-e48f68/3/my-repo	2026-08-05T06:33:30Z
$HOME/Documents/my-projects/firstmate	2026-08-05T06:34:14Z
$HOME/.treehouse/firstmate-253838/4/firstmate	-
LIVE
if [ "$LIVE_RUN" -eq 0 ]; then
  echo "skip: report §3.3 live worktrees not present on this machine"
elif [ "$LIVE_EXACT" -eq 0 ]; then
  pass "report §3.3: $LIVE_RUN live worktree(s) read, every one a valid verdict"
  echo "skip: no recorded §3.3 death is still the newest in its transcript - all $LIVE_RUN have been superseded by newer sessions, so byte-exact reproduction was NOT checked here; the committed tests/fixtures/limit-sense/ cases are the coverage for that"
else
  pass "report §3.3: $LIVE_RUN live worktree(s) read, $LIVE_EXACT recorded death(s) reproduced exactly"
fi

pass "fm-limit-sense: all cases"
