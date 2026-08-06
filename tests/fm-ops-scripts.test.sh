#!/usr/bin/env bash
# Behavior tests for the four operational scripts landed from the captain's
# primary checkout: the X collectors (bin/fm-collect-x-user.sh,
# bin/fm-collect-fizzychats.sh) and the GMGN Telegram pair
# (bin/fm-gmgn-tg-login.sh, bin/fm-gmgn-tg-watch.sh).
#
# All four talk to the network or to a Telegram session in real use, so every
# case here runs against a fakebin `curl`, `tg`, and `tmux`: no request leaves
# the machine and no real tmux session is touched.
#
# The cases pin the operator-visible contract plus the review fixes that landed
# with the scripts:
#   (a) cold start bootstraps watch-ids.txt, posts/, media/, and posts-index.json
#   (b) a hand-annotated watch list survives a run (the index rewrite merges,
#       it does not clobber comments)
#   (c) the author check is case-insensitive: X returns display casing
#       ("TestUser") while the collector normalises the handle
#   (d) a foreign author or a non-200 API code is rejected and leaves NO post
#       file and no leftover temp file in posts/
#   (e) handles and status ids are validated before any fetch
#   (f) --help prints the whole header block, Environment section included
#   (g) fm-gmgn-tg-login.sh targets the tmux SESSION NAME from
#       `display-message -p '#S'`, never the raw $TMUX socket path, and reuses
#       an existing fm-tg-login window instead of stacking a second one
#   (h) fm-gmgn-tg-watch.sh posts new channel messages to the deck ingest
#       endpoint and falls back to the local inbox when the deck is down
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

X_COLLECT="$ROOT/bin/fm-collect-x-user.sh"
FIZZY_COLLECT="$ROOT/bin/fm-collect-fizzychats.sh"
TG_LOGIN="$ROOT/bin/fm-gmgn-tg-login.sh"
TG_WATCH="$ROOT/bin/fm-gmgn-tg-watch.sh"

TMP_ROOT=$(fm_test_tmproot fm-ops-scripts)

ID_A=1234567890123456780
ID_B=1234567890123456781
ID_FOREIGN=1234567890123456782
ID_PRIVATE=1234567890123456783

# --- fakes ------------------------------------------------------------------

# A fake `curl` that serves the collectors' post/media fetches from a fixture
# directory and the watcher's ingest POST from an env-controlled deck state.
# It understands only the flags these four scripts actually pass.
write_fake_curl() {  # <fakebin>
  cat > "$1/curl" <<'SH'
#!/usr/bin/env bash
set -u
out=""
url=""
data=""
is_post=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) shift; out=${1:-} ;;
    -X) shift; if [ "${1:-}" = "POST" ]; then is_post=1; fi ;;
    -d) shift; data=${1:-} ;;
    -H|-m|--max-time) shift ;;
    -*) : ;;
    *) url=$1 ;;
  esac
  shift || true
done

if [ -n "$is_post" ]; then
  if [ -n "${FM_FAKE_DECK_DOWN:-}" ]; then
    exit 7
  fi
  printf '%s\n' "$data" >> "${FM_FAKE_DECK_LOG:-/dev/null}"
  exit 0
fi

if [ -z "$out" ]; then
  exit 0
fi

case "$url" in
  */media/*)
    # Media payload must clear the collector's 100-byte "did it download"
    # floor, so emit a fixed block well above it.
    : > "$out"
    i=0
    while [ "$i" -lt 40 ]; do
      printf 'FAKE-JPEG-BYTES' >> "$out"
      i=$((i + 1))
    done
    exit 0
    ;;
  */status/*)
    id=${url##*/}
    if [ -f "${FM_FAKE_X_DIR:-}/$id.json" ]; then
      cat "${FM_FAKE_X_DIR}/$id.json" > "$out"
    else
      printf '{"code":404,"message":"NOT_FOUND"}\n' > "$out"
    fi
    exit 0
    ;;
esac
printf 'fake-asset\n' > "$out"
exit 0
SH
  chmod +x "$1/curl"
}

# A fake `tmux` that records every command it is asked to run and keeps a
# window list per target, so the login script's target resolution is provable.
write_fake_tmux() {  # <fakebin>
  cat > "$1/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_FAKE_TMUX_LOG:-/dev/null}"
windows="${FM_FAKE_TMUX_WINDOWS:-/dev/null}"
case "${1:-}" in
  display-message)
    printf '%s\n' "${FM_FAKE_TMUX_SESSION:-}"
    exit 0
    ;;
  list-windows)
    if [ -f "$windows" ]; then
      cat "$windows"
    fi
    exit 0
    ;;
  new-window)
    printf 'fm-tg-login\n' >> "$windows"
    exit 0
    ;;
  select-window)
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$1/tmux"
}

# A fake gotd/cli `tg`: login/init succeed, whoami reflects FM_FAKE_TG_LOGGED_OUT,
# and `chats list` serves the channel snapshot from FM_FAKE_TG_CHATS.
write_fake_tg() {  # <path>
  cat > "$1" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  init) exit 0 ;;
  login) printf '[QR CODE] tg://login?token=fake\n'; exit 0 ;;
  whoami)
    if [ -n "${FM_FAKE_TG_LOGGED_OUT:-}" ]; then
      exit 1
    fi
    printf '{"data":{"user":{"id":1}}}\n'
    exit 0
    ;;
  chats)
    if [ -f "${FM_FAKE_TG_CHATS:-}" ]; then
      cat "${FM_FAKE_TG_CHATS}"
    else
      printf '{"data":{"chats":[]}}\n'
    fi
    exit 0
    ;;
esac
exit 2
SH
  chmod +x "$1"
}

# An fxtwitter-shaped post fixture. Author casing is caller-controlled because
# the real API returns the display casing, not the lowercase handle.
write_post_fixture() {  # <dir> <id> <author> [code]
  local dir=$1 id=$2 author=$3 code=${4:-200}
  mkdir -p "$dir"
  if [ "$code" != "200" ]; then
    printf '{"code":%s,"message":"PRIVATE_TWEET"}\n' "$code" > "$dir/$id.json"
    return 0
  fi
  cat > "$dir/$id.json" <<EOF
{
  "code": 200,
  "message": "OK",
  "tweet": {
    "id": "$id",
    "url": "https://x.com/$author/status/$id",
    "created_at": "Wed Aug 06 09:12:00 +0000 2026",
    "text": "sample post $id",
    "likes": 12,
    "retweets": 3,
    "replies": 1,
    "views": 900,
    "author": { "screen_name": "$author", "name": "$author" },
    "media": { "photos": [ { "url": "https://pbs.example.invalid/media/$id.jpg" } ] }
  }
}
EOF
}

# --- fm-collect-x-user.sh ---------------------------------------------------

test_x_collector_cold_start_and_watch_merge() {
  local work fakebin out dest
  work="$TMP_ROOT/x-cold"
  mkdir -p "$work"
  fakebin=$(fm_fakebin "$work")
  write_fake_curl "$fakebin"
  dest="$work/reference-x-testuser"

  FM_FAKE_X_DIR="$work/fixtures"
  export FM_FAKE_X_DIR
  write_post_fixture "$FM_FAKE_X_DIR" "$ID_A" TestUser
  write_post_fixture "$FM_FAKE_X_DIR" "$ID_B" TestUser

  # (a) cold start: no watch file yet, one id on the command line. The handle is
  # passed with an @ and in display casing to pin normalisation.
  out=$(PATH="$fakebin:$PATH" FM_X_COLLECT_DIR="$dest" \
    FM_X_API="https://api.example.invalid" "$X_COLLECT" @TestUser "$ID_A" 2>&1)
  expect_code 0 $? "x collector cold start should succeed"
  assert_contains "$out" "ok $ID_A" "cold start should report the collected id"
  [ -f "$dest/posts/$ID_A.json" ] || fail "cold start should keep the post json"
  [ -f "$dest/posts-index.json" ] || fail "cold start should write posts-index.json"
  assert_grep "$ID_A" "$dest/watch-ids.txt" \
    "cold start should bootstrap watch-ids.txt with the collected id"
  [ -s "$dest/media/${ID_A}_0.jpg" ] || fail "cold start should download post media"

  # (c) the fixture author is "TestUser" while the handle normalises to
  # "testuser": the case-insensitive check must accept it.
  assert_not_contains "$out" "skip $ID_A" \
    "display-cased author must not be treated as a foreign author"

  # (b) an operator's comments and inline annotations must survive the next run.
  cat > "$dest/watch-ids.txt" <<EOF
# @testuser status ids to keep harvesting
$ID_A   # the gm post
EOF
  out=$(PATH="$fakebin:$PATH" FM_X_COLLECT_DIR="$dest" \
    FM_X_API="https://api.example.invalid" "$X_COLLECT" testuser \
    --url "https://x.com/testuser/status/$ID_B" 2>&1)
  expect_code 0 $? "x collector --url run should succeed"
  assert_grep "# @testuser status ids to keep harvesting" "$dest/watch-ids.txt" \
    "the watch list comment header must survive an index rewrite"
  assert_grep "# the gm post" "$dest/watch-ids.txt" \
    "an inline watch-list annotation must survive an index rewrite"
  assert_grep "$ID_B" "$dest/watch-ids.txt" \
    "a newly collected id must be appended to the watch list"

  pass "fm-collect-x-user.sh bootstraps a destination and merges the watch list"
}

test_x_collector_rejects_bad_input_without_partials() {
  local work fakebin out rc dest leftovers
  work="$TMP_ROOT/x-reject"
  mkdir -p "$work"
  fakebin=$(fm_fakebin "$work")
  write_fake_curl "$fakebin"
  dest="$work/reference-x-testuser"

  FM_FAKE_X_DIR="$work/fixtures"
  export FM_FAKE_X_DIR
  write_post_fixture "$FM_FAKE_X_DIR" "$ID_FOREIGN" SomeoneElse
  write_post_fixture "$FM_FAKE_X_DIR" "$ID_PRIVATE" TestUser 401

  # (e) a handle carrying shell metacharacters is refused before any fetch.
  out=$(PATH="$fakebin:$PATH" FM_X_COLLECT_DIR="$dest" \
    FM_X_API="https://api.example.invalid" "$X_COLLECT" 'evil$(id)/../x' 2>&1)
  rc=$?
  expect_code 1 "$rc" "an invalid handle must be refused"
  assert_contains "$out" "invalid handle" "the refusal should name the bad handle"

  # (e) a non-numeric positional argument is refused instead of being fetched.
  out=$(PATH="$fakebin:$PATH" FM_X_COLLECT_DIR="$dest" \
    FM_X_API="https://api.example.invalid" "$X_COLLECT" testuser 'not-an-id' 2>&1)
  rc=$?
  expect_code 1 "$rc" "a non-numeric status id must be refused"
  assert_contains "$out" "not a status id" "the refusal should name the bad id"

  # (d) foreign author and non-200 code are both rejected, and neither leaves a
  # post file or a stray temp file behind.
  out=$(PATH="$fakebin:$PATH" FM_X_COLLECT_DIR="$dest" \
    FM_X_API="https://api.example.invalid" "$X_COLLECT" testuser \
    "$ID_FOREIGN" "$ID_PRIVATE" 2>&1)
  assert_contains "$out" "skip $ID_FOREIGN author=SomeoneElse" \
    "a post by another author must be skipped"
  assert_contains "$out" "fail $ID_PRIVATE code=401" \
    "a non-200 API code must be reported as a failure"
  [ -f "$dest/posts/$ID_FOREIGN.json" ] && fail "a foreign-author post must not be kept"
  [ -f "$dest/posts/$ID_PRIVATE.json" ] && fail "a non-200 response must not be kept"
  leftovers=$(find "$dest/posts" -name '.*' -type f 2>/dev/null)
  [ -z "$leftovers" ] || fail "rejected fetches left temp files behind: $leftovers"

  pass "fm-collect-x-user.sh refuses bad input and leaves no partial files"
}

test_collectors_help_prints_full_header() {
  local out
  out=$("$X_COLLECT" --help 2>&1)
  expect_code 0 $? "fm-collect-x-user.sh --help should exit 0"
  assert_contains "$out" "Usage:" "x collector help should show usage"
  assert_contains "$out" "FM_X_COLLECT_DIR" \
    "x collector help must reach the Environment block, not stop mid-header"

  out=$("$FIZZY_COLLECT" --help 2>&1)
  expect_code 0 $? "fm-collect-fizzychats.sh --help should exit 0"
  assert_contains "$out" "Usage:" "fizzychats help should show usage"
  assert_contains "$out" "FM_FIZZY_HANDLE" \
    "fizzychats help must reach the Environment block, not stop mid-header"

  pass "both collectors print their complete --help header"
}

# --- fm-collect-fizzychats.sh -----------------------------------------------

test_fizzy_collector_collects_and_indexes() {
  local work fakebin out dest ids
  work="$TMP_ROOT/fizzy"
  mkdir -p "$work"
  fakebin=$(fm_fakebin "$work")
  write_fake_curl "$fakebin"
  dest="$work/reference-fizzychats"

  FM_FAKE_X_DIR="$work/fixtures"
  export FM_FAKE_X_DIR
  write_post_fixture "$FM_FAKE_X_DIR" "$ID_A" fizzychats

  # No ids anywhere is an actionable error, never a silent success.
  out=$(PATH="$fakebin:$PATH" FM_FIZZY_DIR="$dest" \
    FM_FIZZY_API="https://api.example.invalid" "$FIZZY_COLLECT" 2>&1)
  expect_code 1 $? "an empty watch list with no arguments must fail loudly"
  assert_contains "$out" "no status ids" "the failure should point at the watch file"

  out=$(PATH="$fakebin:$PATH" FM_FIZZY_DIR="$dest" \
    FM_FIZZY_API="https://api.example.invalid" "$FIZZY_COLLECT" "$ID_A" 2>&1)
  expect_code 0 $? "collecting one fizzychats post should succeed"
  assert_contains "$out" "ok $ID_A" "the run should report the collected id"
  assert_grep "$ID_A" "$dest/watch-ids.txt" "the id should be added to the watch list"
  ids=$(python3 -c 'import json,sys;print(",".join(r["id"] for r in json.load(open(sys.argv[1]))))' \
    "$dest/posts-index.json")
  [ "$ids" = "$ID_A" ] || fail "posts-index.json should index exactly the collected post, got: $ids"
  assert_grep "media/${ID_A}_0.jpg" "$dest/posts-index.json" \
    "the index should point at the locally saved media file"

  pass "fm-collect-fizzychats.sh collects a post, media, and the index"
}

# --- fm-gmgn-tg-login.sh ----------------------------------------------------

test_tg_login_targets_the_session_name() {
  local work fakebin out
  work="$TMP_ROOT/tg-login"
  mkdir -p "$work"
  fakebin=$(fm_fakebin "$work")
  write_fake_tmux "$fakebin"
  write_fake_tg "$work/tg"

  FM_FAKE_TMUX_LOG="$work/tmux.log"
  FM_FAKE_TMUX_WINDOWS="$work/windows.txt"
  FM_FAKE_TMUX_SESSION="captain"
  export FM_FAKE_TMUX_LOG FM_FAKE_TMUX_WINDOWS FM_FAKE_TMUX_SESSION
  : > "$FM_FAKE_TMUX_LOG"
  printf 'main\n' > "$FM_FAKE_TMUX_WINDOWS"

  # $TMUX's first field is the SOCKET PATH, not the session name: targeting it
  # is what made the pre-fix script fail with "can't find window".
  out=$(PATH="$fakebin:$PATH" TG_BIN="$work/tg" \
    TMUX="/private/tmp/tmux-501/default,12345,2" "$TG_LOGIN" 2>&1)
  expect_code 0 $? "login inside tmux should succeed"
  assert_contains "$out" "Opened fm-tg-login tmux window" \
    "the first run should open the login window"
  assert_grep "new-window -t captain -n fm-tg-login" "$FM_FAKE_TMUX_LOG" \
    "the login window must be created in the resolved session name"
  assert_grep "select-window -t captain:fm-tg-login" "$FM_FAKE_TMUX_LOG" \
    "the login window must be selected by session-qualified name"
  if grep -F -- "/private/tmp/tmux-501/default" "$FM_FAKE_TMUX_LOG" >/dev/null; then
    fail "the raw \$TMUX socket path must never be used as a tmux target"
  fi

  # Second run: the window already exists, so switch instead of stacking.
  : > "$FM_FAKE_TMUX_LOG"
  out=$(PATH="$fakebin:$PATH" TG_BIN="$work/tg" \
    TMUX="/private/tmp/tmux-501/default,12345,2" "$TG_LOGIN" 2>&1)
  expect_code 0 $? "a repeat login should succeed"
  assert_contains "$out" "Switched to existing fm-tg-login window" \
    "a repeat run should reuse the existing window"
  if grep -F -- "new-window" "$FM_FAKE_TMUX_LOG" >/dev/null; then
    fail "a repeat run must not open a second fm-tg-login window"
  fi

  # A missing tg binary is an actionable refusal, not a confusing tmux error.
  out=$(PATH="$fakebin:$PATH" TG_BIN="$work/absent-tg" "$TG_LOGIN" 2>&1)
  expect_code 1 $? "a missing tg binary must fail"
  assert_contains "$out" "tg not found" "the refusal should say where tg was expected"

  unset FM_FAKE_TMUX_LOG FM_FAKE_TMUX_WINDOWS FM_FAKE_TMUX_SESSION
  pass "fm-gmgn-tg-login.sh resolves the tmux session name and reuses its window"
}

# --- fm-gmgn-tg-watch.sh ----------------------------------------------------

# Start the watcher, let it take its cold-start baseline from the channel
# snapshot that is already on screen, then publish a NEW message and wait for
# the watcher to route it. Baselining on start is deliberate: it stops a
# restart from re-ingesting the alert the operator has already seen.
run_watcher_for_new_message() {  # <wait-file> <chats-file> <new-json> <command...>
  local wait_file=$1 chats_file=$2 new_json=$3 pid waited
  shift 3
  "$@" >/dev/null 2>&1 &
  pid=$!
  sleep 2
  printf '%s\n' "$new_json" > "$chats_file"
  waited=0
  while [ "$waited" -lt 15 ]; do
    if [ -s "$wait_file" ]; then
      break
    fi
    sleep 1
    waited=$((waited + 1))
  done
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
}

test_tg_watch_ingests_and_falls_back() {
  local work fakebin chats inbox decklog
  work="$TMP_ROOT/tg-watch"
  mkdir -p "$work"
  fakebin=$(fm_fakebin "$work")
  write_fake_curl "$fakebin"
  write_fake_tg "$work/tg"
  chats="$work/chats.json"
  inbox="$work/inbox.jsonl"
  decklog="$work/deck.log"

  FM_FAKE_TG_CHATS="$chats"
  export FM_FAKE_TG_CHATS

  # Not logged in: refuse with the recovery command instead of polling forever.
  local out
  out=$(PATH="$fakebin:$PATH" TG_BIN="$work/tg" FM_FAKE_TG_LOGGED_OUT=1 \
    GMGN_TELEGRAM_INBOX="$inbox" "$TG_WATCH" 2>&1)
  expect_code 1 $? "the watcher must refuse when tg is not logged in"
  assert_contains "$out" "bin/fm-gmgn-tg-login.sh" \
    "the refusal should name the login script"

  # A new channel message reaches the deck ingest endpoint.
  printf '{"data":{"chats":[{"peer":{"id":2115686230},"last_date":1785000000,"last_message":"older alert"}]}}\n' \
    > "$chats"
  : > "$decklog"
  FM_FAKE_DECK_LOG="$decklog"
  export FM_FAKE_DECK_LOG
  unset FM_FAKE_DECK_DOWN
  run_watcher_for_new_message "$decklog" "$chats" \
    '{"data":{"chats":[{"peer":{"id":2115686230},"last_date":1785000600,"last_message":"Pump Alert SPOODY"}]}}' \
    env PATH="$fakebin:$PATH" TG_BIN="$work/tg" \
    TELEGRAM_GMGN_POLL_SEC=1 GMGN_TELEGRAM_INBOX="$inbox" "$TG_WATCH"
  [ -s "$decklog" ] || fail "the watcher should have posted the channel message to the deck"
  assert_grep '"text":"Pump Alert SPOODY"' "$decklog" \
    "the deck payload should carry the channel message text"
  assert_grep '"channelId":2115686230' "$decklog" \
    "the deck payload should carry the numeric channel id"

  # Deck unreachable: queue to the local inbox instead of dropping the alert.
  printf '{"data":{"chats":[{"peer":{"id":2115686230},"last_date":1785000900,"last_message":"older alert"}]}}\n' \
    > "$chats"
  : > "$inbox"
  FM_FAKE_DECK_DOWN=1
  export FM_FAKE_DECK_DOWN
  run_watcher_for_new_message "$inbox" "$chats" \
    '{"data":{"chats":[{"peer":{"id":2115686230},"last_date":1785001200,"last_message":"Pump Alert FADEGUARD"}]}}' \
    env PATH="$fakebin:$PATH" TG_BIN="$work/tg" \
    TELEGRAM_GMGN_POLL_SEC=1 GMGN_TELEGRAM_INBOX="$inbox" "$TG_WATCH"
  [ -s "$inbox" ] || fail "the watcher should queue the alert to the fallback inbox"
  assert_grep '"source":"gmgn_telegram"' "$inbox" "the inbox line should be tagged"
  assert_grep 'Pump Alert FADEGUARD' "$inbox" "the inbox line should carry the alert text"
  assert_grep '"at":"2026-07-25T17:40:00Z"' "$inbox" \
    "the inbox line should carry the message epoch rendered as UTC ISO-8601"
  unset FM_FAKE_DECK_DOWN FM_FAKE_DECK_LOG FM_FAKE_TG_CHATS

  pass "fm-gmgn-tg-watch.sh ingests to the deck and falls back to the inbox"
}

test_x_collector_cold_start_and_watch_merge
test_x_collector_rejects_bad_input_without_partials
test_collectors_help_prints_full_header
test_fizzy_collector_collects_and_indexes
test_tg_login_targets_the_session_name
if command -v jq >/dev/null 2>&1; then
  test_tg_watch_ingests_and_falls_back
else
  printf 'note: jq not installed - fm-gmgn-tg-watch.sh cases not exercised\n'
fi
