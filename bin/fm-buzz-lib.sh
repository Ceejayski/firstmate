#!/usr/bin/env bash
# Shared config resolution and composition for the opt-in Buzz fleet bridge
# (fm-buzz-status.sh and fm-buzz-enqueue.sh).
#
# The bridge mirrors the X-mode opt-in pattern: it is INERT until the captain
# configures a channel. Nothing here runs at bootstrap, arms a watcher, or
# changes any non-Buzz behavior. docs/buzz-bridge.md owns the captain-facing
# opt-in guide; docs/configuration.md owns the config schema.
#
# Config resolution order for every key: explicit environment variable, then
# the gitignored $FM_HOME/config/buzz-bridge.env, then $FM_HOME/.env.
# FMB_ENV_FILE can point direct invocations at another .env-style file in
# place of config/buzz-bridge.env (mirrors FMX_ENV_FILE).
#
# Keys (all optional; the bridge without a channel is a hard no-op):
#   BUZZ_BRIDGE_CHANNEL   channel UUID to post to / poll (from `buzz channels list`)
#   BUZZ_PRIVATE_KEY      Nostr key (hex or nsec) for the bridge identity;
#                         NEVER printed, logged, or placed on a command line -
#                         it is passed to the buzz CLI via the environment only
#   BUZZ_RELAY_URL        relay base URL; empty defers to the buzz CLI default
#   BUZZ_BRIDGE_DRY_RUN   truthy = compose and print instead of posting
#   BUZZ_BRIDGE_BIN       buzz CLI executable override (tests use a fake)
#
# This file is sourced, never executed. It defines:
#   fmb_load_config   - resolve FMB_CHANNEL, FMB_KEY, FMB_RELAY, FMB_DRY, FMB_BIN
#   fmb_send          - post stdin as one message to FMB_CHANNEL via the CLI
#   fmb_snapshot      - compose the public-safe fleet snapshot text
# Callers must have FM_HOME set before calling fmb_load_config.
#
# Secrets discipline: FMB_KEY is exported only into the buzz CLI subprocess
# environment. No function in this file prints it, and callers must not either.

# shellcheck source=bin/fm-x-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-x-lib.sh"

# fmb_env_pick <env-var-name> <key> <file> <fallback-file>: explicit environment
# wins, then <file>, then <fallback-file>. Prints the resolved value (possibly
# empty). Uses fm-x-lib.sh's fmx_env_get as the single owner of .env parsing.
fmb_env_pick() {
  local var=$1 key=$2 file=$3 fallback=$4 val
  if eval "[ -n \"\${$var+x}\" ]"; then
    eval "printf '%s' \"\${$var-}\""
    return 0
  fi
  val=$(fmx_env_get "$key" "$file")
  [ -n "$val" ] || val=$(fmx_env_get "$key" "$fallback")
  printf '%s' "$val"
}

# Resolve the bridge settings into FMB_CHANNEL, FMB_KEY, FMB_RELAY, FMB_DRY
# (1 or empty), and FMB_BIN. Safe to call with nothing configured: every value
# simply resolves empty (FMB_BIN defaults to `buzz`).
fmb_load_config() {
  local cfg="${FMB_ENV_FILE:-$FM_HOME/config/buzz-bridge.env}" env_file="$FM_HOME/.env" dry
  FMB_CHANNEL=$(fmb_env_pick BUZZ_BRIDGE_CHANNEL BUZZ_BRIDGE_CHANNEL "$cfg" "$env_file")
  FMB_KEY=$(fmb_env_pick BUZZ_PRIVATE_KEY BUZZ_PRIVATE_KEY "$cfg" "$env_file")
  FMB_RELAY=$(fmb_env_pick BUZZ_RELAY_URL BUZZ_RELAY_URL "$cfg" "$env_file")
  FMB_BIN=$(fmb_env_pick BUZZ_BRIDGE_BIN BUZZ_BRIDGE_BIN "$cfg" "$env_file")
  [ -n "$FMB_BIN" ] || FMB_BIN=buzz
  dry=$(fmb_env_pick BUZZ_BRIDGE_DRY_RUN BUZZ_BRIDGE_DRY_RUN "$cfg" "$env_file")
  # shellcheck disable=SC2034 # FMB_DRY is read by sourcing callers.
  case "$(printf '%s' "$dry" | tr '[:upper:]' '[:lower:]')" in
    ''|0|false|no|off) FMB_DRY="" ;;
    *) FMB_DRY=1 ;;
  esac
  # A key with a newline would corrupt the subprocess environment handoff.
  case "$FMB_KEY" in
    *$'\n'*|*$'\r'*) FMB_KEY="" ;;
  esac
}

# fmb_send: post stdin as one message to the configured channel. The key and
# relay ride the subprocess environment only; the CLI's stdout (an event-id
# JSON envelope) is discarded and its stderr passes through, so a failure
# surfaces as a key-free CLI diagnostic plus this function's exit code.
# Requires fmb_load_config first and a non-empty FMB_CHANNEL and FMB_KEY.
fmb_send() {
  if [ -n "$FMB_RELAY" ]; then
    BUZZ_PRIVATE_KEY="$FMB_KEY" BUZZ_RELAY_URL="$FMB_RELAY" \
      "$FMB_BIN" messages send --channel "$FMB_CHANNEL" --content - >/dev/null
  else
    BUZZ_PRIVATE_KEY="$FMB_KEY" \
      "$FMB_BIN" messages send --channel "$FMB_CHANNEL" --content - >/dev/null
  fi
}

# fmb_fetch <args...>: run a read-only buzz CLI subcommand with the bridge
# identity in the subprocess environment, printing the CLI's stdout.
fmb_fetch() {
  if [ -n "$FMB_RELAY" ]; then
    BUZZ_PRIVATE_KEY="$FMB_KEY" BUZZ_RELAY_URL="$FMB_RELAY" "$FMB_BIN" "$@"
  else
    BUZZ_PRIVATE_KEY="$FMB_KEY" "$FMB_BIN" "$@"
  fi
}

# fmb_format_entry <backlog-line> <state-dir>: print one public-safe bullet for
# a top-level backlog entry. Drops the internal task id, any blocked-by task
# ids and reasons, and the "(kind: ...)" / "(since ...)" / "(priority: ...)" /
# "(hold: ...)" / "(hold-kind: ...)" / "(merged ...)" / "(reported ...)" /
# "(done ...)" markers, keeps the human title and "(repo: ...)", and appends
# the recorded PR URL from state/<id>.meta when one exists. The blocked-by/
# kind/since/priority/hold/merged/reported/done marker set mirrors the
# canonical backlog metadata stripped by fm-fleet-snapshot.sh's title_of.
fmb_format_entry() {
  local line=$1 state_dir=$2 rest id title pr
  rest=${line#*\] }
  id=${rest%% *}
  title=${rest#"$id"}
  title=${title# - }
  title=$(printf '%s' "$title" | sed -E '
    s/[[:space:]]*blocked-by:[[:space:]]+[^[:space:])]+[[:space:]]+-[[:space:]]+.*$//
    s/[[:space:]]*blocked-by:[[:space:]]+[^[:space:]]+//g
    s/ \(kind: [^)]*\)//g
    s/ \(since [^)]*\)//g
    s/ \(priority: [^)]*\)//g
    s/ \(hold: [^)]*\)//g
    s/ \(hold-kind: [^)]*\)//g
    s/ \(merged [^)]*\)//g
    s/ \(reported [^)]*\)//g
    s/ \(done [^)]*\)//g
  ')
  pr=""
  case "$id" in
    ''|*[!A-Za-z0-9._-]*) ;;
    *)
      if [ -f "$state_dir/$id.meta" ]; then
        pr=$(grep '^pr=' "$state_dir/$id.meta" 2>/dev/null | tail -n1) || pr=""
        pr=${pr#pr=}
      fi
      ;;
  esac
  if [ -n "$pr" ]; then
    printf '%s - PR %s\n' "$title" "$pr"
  else
    printf '%s\n' "$title"
  fi
}

# fmb_snapshot: compose the public-safe fleet snapshot from data/backlog.md and
# state/<id>.meta PR records. In-flight titles are capped at 12 lines and Done
# one-liners at 3 so a busy fleet never floods the channel. Contains no task
# ids, no local paths, no secrets, and nothing read from .env.
fmb_snapshot() {
  local backlog="$FM_HOME/data/backlog.md" state_dir="$FM_HOME/state"
  local inflight_cap=12 done_cap=3
  local section="" line entry inflight_count=0 done_count=0 shown=0
  local inflight_lines="" done_lines=""
  if [ -f "$backlog" ]; then
    while IFS= read -r line; do
      case "$line" in
        '## In flight'*) section=inflight; continue ;;
        '## Done'*) section="done"; continue ;;
        '## '*) section=other; continue ;;
      esac
      case "$line" in
        '- ['*']'*) ;;
        *) continue ;;
      esac
      entry=$(fmb_format_entry "$line" "$state_dir")
      case "$section" in
        inflight)
          inflight_count=$((inflight_count + 1))
          if [ "$inflight_count" -le "$inflight_cap" ]; then
            inflight_lines="${inflight_lines}• $entry"$'\n'
          fi
          ;;
        done)
          done_count=$((done_count + 1))
          if [ "$done_count" -le "$done_cap" ]; then
            done_lines="${done_lines}✓ $entry"$'\n'
          fi
          ;;
      esac
    done < "$backlog"
  fi
  printf 'Fleet status — %s\n' "$(date -u '+%Y-%m-%d %H:%M UTC')"
  if [ ! -f "$backlog" ]; then
    printf 'No fleet backlog found in this home.\n'
    return 0
  fi
  if [ "$inflight_count" -gt 0 ]; then
    printf 'In flight (%s):\n%s' "$inflight_count" "$inflight_lines"
    shown=$((inflight_count < inflight_cap ? inflight_count : inflight_cap))
    if [ "$inflight_count" -gt "$shown" ]; then
      printf '(+%s more)\n' "$((inflight_count - shown))"
    fi
  else
    printf 'Nothing in flight.\n'
  fi
  if [ "$done_count" -gt 0 ]; then
    printf 'Recently done:\n%s' "$done_lines"
  fi
}
