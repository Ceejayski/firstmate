#!/usr/bin/env bash
# Behavior tests for the opt-in Buzz fleet bridge: the snapshot/custom-line
# poster (fm-buzz-status.sh) and the research-request poll (fm-buzz-enqueue.sh).
#
# The bridge must be INERT by default (no channel -> hard no-op, exit 0, no
# output) and additive when configured. The buzz CLI is stubbed with a fakebin
# `buzz` so these stay hermetic: no relay, no network, deterministic in CI.
# jq stays the real tool. The secret key must ride the subprocess environment
# only and never appear in stdout, stderr, or the CLI argv.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
JQ_DIR=$(command -v jq 2>/dev/null) && JQ_DIR=$(dirname "$JQ_DIR") || JQ_DIR=
[ -n "$JQ_DIR" ] && BASE_PATH="$JQ_DIR:$BASE_PATH"
TMP_ROOT=$(fm_test_tmproot fm-buzz-bridge-tests)

SECRET="nsec1testsecretvaluezz"

# A fakebin `buzz` that records every invocation (argv, key length, relay) to
# FAKE_BUZZ_LOG, reads stdin content for `messages send --content -`, and
# serves FAKE_BUZZ_GET_BODY for `messages get`.
make_fake_buzz() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/buzz" <<'SH'
#!/usr/bin/env bash
if [ -n "${FAKE_BUZZ_LOG:-}" ]; then
  {
    echo "argv=$*"
    echo "keylen=${#BUZZ_PRIVATE_KEY}"
    echo "relay=${BUZZ_RELAY_URL:-}"
  } >> "$FAKE_BUZZ_LOG"
fi
case "${1:-} ${2:-}" in
  'messages send')
    content=$(cat)
    if [ -n "${FAKE_BUZZ_LOG:-}" ]; then
      printf 'content<<EOF\n%s\nEOF\n' "$content" >> "$FAKE_BUZZ_LOG"
    fi
    printf '{"event_id":"e1","accepted":true}\n'
    exit "${FAKE_BUZZ_SEND_RC:-0}"
    ;;
  'messages get')
    printf '%s' "${FAKE_BUZZ_GET_BODY:-[]}"
    exit "${FAKE_BUZZ_GET_RC:-0}"
    ;;
  *)
    exit 4
    ;;
esac
SH
  chmod +x "$fakebin/buzz"
  printf '%s\n' "$fakebin"
}

# make_home <dir>: seed a fixture FM_HOME with a backlog and one PR-linked meta.
make_home() {
  local home=$1
  mkdir -p "$home/data" "$home/state" "$home/config"
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## In flight
- [ ] task-a1 - Fix the widget flow (repo: my-repo) (kind: ship) (since 2026-07-20)
  an indented note line that must not appear
- [ ] task-b2 - Buzz bridge phase two (repo: firstmate) (kind: ship) (since 2026-07-23)
- [ ] task-c3 - Escalate the payment gate blocked-by: task-a1 (repo: my-repo) (kind: ship) (priority: 2) (since 2026-07-22) (hold: captain decision pending) (hold-kind: captain)

## Queued
- [ ] task-q1 - Queued thing (repo: my-repo) (kind: ship)

## Done
- [x] task-d1 - Shipped the thing (repo: my-repo) (kind: ship)
- [x] task-d2 - Scouted the meme trend - data/task-d2/report.md (repo: my-repo) (kind: scout)
- [x] task-d3 - Wrapped up locally - local main (repo: my-repo) (kind: ship)
EOF
  printf 'window=fm-task-a1\npr=https://github.com/x/y/pull/5\n' > "$home/state/task-a1.meta"
}

# write_config <home>: full opt-in config pointing at the fake CLI.
write_config() {
  local home=$1 fakebin=$2
  cat > "$home/config/buzz-bridge.env" <<EOF
BUZZ_BRIDGE_CHANNEL=chan-123
BUZZ_PRIVATE_KEY=$SECRET
BUZZ_RELAY_URL=wss://relay.example
BUZZ_BRIDGE_BIN=$fakebin/buzz
EOF
}

run_status() {
  local home=$1 log=$2; shift 2
  env -i PATH="$BASE_PATH" HOME="$TMP_ROOT" FM_HOME="$home" FAKE_BUZZ_LOG="$log" \
    ${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"} "$ROOT/bin/fm-buzz-status.sh" "$@" \
    > "$TMP_ROOT/out" 2> "$TMP_ROOT/err"
}

run_enqueue() {
  local home=$1 log=$2; shift 2
  env -i PATH="$BASE_PATH" HOME="$TMP_ROOT" FM_HOME="$home" FAKE_BUZZ_LOG="$log" \
    ${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"} "$ROOT/bin/fm-buzz-enqueue.sh" "$@" \
    > "$TMP_ROOT/out" 2> "$TMP_ROOT/err"
}

EXTRA_ENV=()

# --- 1. inert with no config: exit 0, no output, no CLI call ----------------
HOME1="$TMP_ROOT/home1"
make_home "$HOME1"
LOG1="$TMP_ROOT/log1"
run_status "$HOME1" "$LOG1" || fail "unconfigured status must exit 0 (rc=$?)"
[ ! -s "$TMP_ROOT/out" ] || fail "unconfigured status printed stdout: $(cat "$TMP_ROOT/out")"
[ ! -s "$TMP_ROOT/err" ] || fail "unconfigured status printed stderr: $(cat "$TMP_ROOT/err")"
[ ! -e "$LOG1" ] || fail "unconfigured status invoked the buzz CLI"
pass "unconfigured bridge is a hard no-op"

# --- 2. dry-run with no config: preview, no CLI call ------------------------
run_status "$HOME1" "$LOG1" --dry-run || fail "dry-run must exit 0 (rc=$?)"
grep -q 'DRY RUN' "$TMP_ROOT/out" || fail "dry-run preview missing DRY RUN marker"
grep -q '<unset>' "$TMP_ROOT/out" || fail "dry-run preview should show the channel as <unset>"
grep -q 'Fix the widget flow' "$TMP_ROOT/out" || fail "dry-run snapshot missing in-flight title"
grep -q 'https://github.com/x/y/pull/5' "$TMP_ROOT/out" || fail "dry-run snapshot missing PR URL"
grep -q 'Shipped the thing' "$TMP_ROOT/out" || fail "dry-run snapshot missing done line"
grep -q 'Escalate the payment gate (repo: my-repo)$' "$TMP_ROOT/out" \
  || fail "dry-run snapshot did not strip blocked-by/priority/hold/hold-kind markers: $(cat "$TMP_ROOT/out")"
grep -q 'priority: 2\|hold: captain\|hold-kind: captain\|blocked-by' "$TMP_ROOT/out" \
  && fail "dry-run snapshot leaked a priority/hold/hold-kind/blocked-by marker"
grep -q 'task-a1' "$TMP_ROOT/out" && fail "dry-run snapshot leaked an internal task id"
grep -q 'must not appear' "$TMP_ROOT/out" && fail "dry-run snapshot leaked an indented note line"
grep -q 'Queued thing' "$TMP_ROOT/out" && fail "dry-run snapshot included queued items"
grep -q 'Scouted the meme trend (repo: my-repo)$' "$TMP_ROOT/out" \
  || fail "dry-run snapshot did not strip the scout report-path suffix: $(cat "$TMP_ROOT/out")"
grep -q 'Wrapped up locally (repo: my-repo)$' "$TMP_ROOT/out" \
  || fail "dry-run snapshot did not strip the local-main suffix: $(cat "$TMP_ROOT/out")"
grep -q 'report.md\|task-d2\|local main' "$TMP_ROOT/out" \
  && fail "dry-run snapshot leaked a report-path or local-main artifact: $(cat "$TMP_ROOT/out")"
[ ! -e "$LOG1" ] || fail "dry-run invoked the buzz CLI"
pass "dry-run previews the snapshot without any CLI call"

# --- 3. configured post: CLI invoked, key only in env, never printed --------
HOME3="$TMP_ROOT/home3"
make_home "$HOME3"
FAKEBIN=$(make_fake_buzz "$TMP_ROOT/fake3")
write_config "$HOME3" "$FAKEBIN"
LOG3="$TMP_ROOT/log3"
run_status "$HOME3" "$LOG3" || fail "configured post must exit 0 (rc=$?)"
grep -q 'posted: buzz channel chan-123' "$TMP_ROOT/out" || fail "configured post missing confirmation line"
grep -q 'argv=messages send --channel chan-123 --content -' "$LOG3" || fail "CLI argv wrong: $(cat "$LOG3")"
grep -q "keylen=${#SECRET}" "$LOG3" || fail "key did not reach the CLI environment"
grep -q 'relay=wss://relay.example' "$LOG3" || fail "relay did not reach the CLI environment"
grep -q 'Fix the widget flow' "$LOG3" || fail "posted content missing snapshot title"
grep -q "$SECRET" "$TMP_ROOT/out" && fail "secret leaked to stdout"
grep -q "$SECRET" "$TMP_ROOT/err" && fail "secret leaked to stderr"
grep -q "argv=.*$SECRET" "$LOG3" && fail "secret leaked onto the CLI command line"
pass "configured post sends the snapshot with the key confined to the environment"

# --- 4. custom text from stdin ----------------------------------------------
: > "$LOG3"
printf 'milestone: PR https://github.com/x/y/pull/5 is green\n' \
  | env -i PATH="$BASE_PATH" HOME="$TMP_ROOT" FM_HOME="$HOME3" FAKE_BUZZ_LOG="$LOG3" \
      "$ROOT/bin/fm-buzz-status.sh" --text - > "$TMP_ROOT/out" 2> "$TMP_ROOT/err" \
  || fail "custom text post must exit 0 (rc=$?)"
grep -q 'milestone: PR https://github.com/x/y/pull/5 is green' "$LOG3" || fail "custom text did not reach the CLI"
grep -q 'Fleet status' "$LOG3" && fail "custom text post should not include the snapshot"
pass "custom text posts verbatim"

# --- 5. channel set but key missing: one stderr line, exit 0, no post -------
HOME5="$TMP_ROOT/home5"
make_home "$HOME5"
printf 'BUZZ_BRIDGE_CHANNEL=chan-123\nBUZZ_BRIDGE_BIN=%s/buzz\n' "$FAKEBIN" > "$HOME5/config/buzz-bridge.env"
LOG5="$TMP_ROOT/log5"
run_status "$HOME5" "$LOG5" || fail "missing-key status must exit 0 (rc=$?)"
grep -q 'BUZZ_PRIVATE_KEY is not' "$TMP_ROOT/err" || fail "missing-key status must print stderr guidance"
[ ! -e "$LOG5" ] || fail "missing-key status invoked the buzz CLI"
pass "missing key skips the post with guidance and exit 0"

# --- 6. live post failure propagates the CLI exit code ----------------------
: > "$LOG3"
env -i PATH="$BASE_PATH" HOME="$TMP_ROOT" FM_HOME="$HOME3" FAKE_BUZZ_LOG="$LOG3" FAKE_BUZZ_SEND_RC=2 \
  "$ROOT/bin/fm-buzz-status.sh" > "$TMP_ROOT/out" 2> "$TMP_ROOT/err"
[ "$?" -eq 2 ] || fail "failed live post must propagate the CLI exit code"
grep -q 'post to channel chan-123 failed' "$TMP_ROOT/err" || fail "failed live post missing diagnostic"
pass "failed live post surfaces a diagnostic and non-zero exit"

# --- 7. enqueue: research requests surface once, cursor advances ------------
GET_BODY='[{"id":"ev1","content":"fm research: what is the memecoin meta?","created_at":100},{"id":"ev2","content":"hello there","created_at":101},{"id":"ev3","content":"FM: scout web  gmgn quick-profit setups","created_at":102}]'
: > "$LOG3"
EXTRA_ENV=(FAKE_BUZZ_GET_BODY="$GET_BODY")
run_enqueue "$HOME3" "$LOG3" || fail "enqueue must exit 0 (rc=$?)"
grep -q '^buzz-research ev1 what is the memecoin meta?$' "$TMP_ROOT/out" || fail "enqueue missed the fm research shape: $(cat "$TMP_ROOT/out")"
grep -q '^buzz-research ev3 gmgn quick-profit setups$' "$TMP_ROOT/out" || fail "enqueue missed the fm: scout web shape: $(cat "$TMP_ROOT/out")"
grep -q 'ev2' "$TMP_ROOT/out" && fail "enqueue surfaced a non-request message"
[ "$(cat "$HOME3/state/buzz-bridge.cursor")" = 102 ] || fail "cursor did not advance to max created_at"
run_enqueue "$HOME3" "$LOG3" || fail "second enqueue must exit 0 (rc=$?)"
[ ! -s "$TMP_ROOT/out" ] || fail "second enqueue re-surfaced already-seen requests: $(cat "$TMP_ROOT/out")"
grep -q -- '--since 102' "$LOG3" || fail "second enqueue did not pass the cursor as --since"
pass "enqueue surfaces each research request exactly once"

# --- 8. enqueue --peek does not advance the cursor --------------------------
HOME8="$TMP_ROOT/home8"
make_home "$HOME8"
write_config "$HOME8" "$FAKEBIN"
LOG8="$TMP_ROOT/log8"
run_enqueue "$HOME8" "$LOG8" --peek || fail "peek must exit 0 (rc=$?)"
grep -q '^buzz-research ev1 ' "$TMP_ROOT/out" || fail "peek did not surface the pending request"
[ ! -e "$HOME8/state/buzz-bridge.cursor" ] || fail "peek advanced the cursor"
pass "peek reads without advancing the cursor"

# --- 9. enqueue is inert without a channel ----------------------------------
EXTRA_ENV=()
LOG9="$TMP_ROOT/log9"
run_enqueue "$HOME1" "$LOG9" || fail "unconfigured enqueue must exit 0 (rc=$?)"
[ ! -s "$TMP_ROOT/out" ] || fail "unconfigured enqueue printed stdout"
[ ! -s "$TMP_ROOT/err" ] || fail "unconfigured enqueue printed stderr"
[ ! -e "$LOG9" ] || fail "unconfigured enqueue invoked the buzz CLI"
pass "unconfigured enqueue is a hard no-op"

echo "all fm-buzz-bridge tests passed"
