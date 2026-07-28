#!/usr/bin/env bash
# Post a short public-safe fleet snapshot, or a custom line, to the configured
# Buzz channel (the opt-in fleet bridge; see docs/buzz-bridge.md).
#
# Usage:
#   fm-buzz-status.sh                 post the composed fleet snapshot
#   fm-buzz-status.sh --dry-run       print what would post; no network at all
#   fm-buzz-status.sh --text <file>   post the file's contents instead
#   fm-buzz-status.sh --text -        post custom text read from stdin
#   fm-buzz-status.sh -               shorthand for --text -
#
# Inert by default: with no BUZZ_BRIDGE_CHANNEL configured this is a hard no-op
# (exit 0, no output) unless --dry-run asked for the preview. A configured
# channel with no BUZZ_PRIVATE_KEY prints one stderr guidance line and still
# exits 0, so an unconfigured or half-configured bridge can never fail the
# fleet. Only a live post that actually reaches the CLI propagates a non-zero
# exit, so an explicit milestone post can be retried by its caller.
#
# The snapshot is composed by fm-buzz-lib.sh:fmb_snapshot from data/backlog.md
# and recorded PR URLs; it contains no task ids, paths, or secrets. Custom text
# should follow the same public-safety rule: captain-relevant outcomes only,
# never key material or internal records. Config keys and resolution order are
# owned by bin/fm-buzz-lib.sh; the opt-in guide is docs/buzz-bridge.md.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
# shellcheck source=bin/fm-buzz-lib.sh
. "$SCRIPT_DIR/fm-buzz-lib.sh"

DRY_FLAG=""
TEXT_SRC=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_FLAG=1; shift ;;
    --text)
      [ "$#" -ge 2 ] || { echo "fm-buzz-status: --text needs a file path or -" >&2; exit 2; }
      TEXT_SRC=$2; shift 2 ;;
    -) TEXT_SRC=-; shift ;;
    -h|--help)
      sed -n '2,23p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "fm-buzz-status: unknown argument: $1" >&2; exit 2 ;;
  esac
done

fmb_load_config

if [ -n "$TEXT_SRC" ]; then
  if [ "$TEXT_SRC" = - ]; then
    MESSAGE=$(cat)
  else
    [ -f "$TEXT_SRC" ] || { echo "fm-buzz-status: no such text file: $TEXT_SRC" >&2; exit 2; }
    MESSAGE=$(cat "$TEXT_SRC")
  fi
  [ -n "$MESSAGE" ] || { echo "fm-buzz-status: refusing to post empty text" >&2; exit 2; }
else
  MESSAGE=$(fmb_snapshot)
fi

if [ -n "$DRY_FLAG" ] || [ -n "$FMB_DRY" ]; then
  printf 'DRY RUN — would post to Buzz channel %s:\n' "${FMB_CHANNEL:-<unset>}"
  printf '%s\n' "$MESSAGE"
  exit 0
fi

[ -n "$FMB_CHANNEL" ] || exit 0
if [ -z "$FMB_KEY" ]; then
  echo "fm-buzz-status: BUZZ_BRIDGE_CHANNEL is set but BUZZ_PRIVATE_KEY is not; skipping post (see docs/buzz-bridge.md)" >&2
  exit 0
fi
if ! command -v "$FMB_BIN" >/dev/null 2>&1; then
  echo "fm-buzz-status: buzz CLI not found ($FMB_BIN); skipping post (see docs/buzz-bridge.md)" >&2
  exit 0
fi

if printf '%s\n' "$MESSAGE" | fmb_send; then
  printf 'posted: buzz channel %s\n' "$FMB_CHANNEL"
else
  rc=$?
  echo "fm-buzz-status: post to channel $FMB_CHANNEL failed (exit $rc)" >&2
  exit "$rc"
fi
