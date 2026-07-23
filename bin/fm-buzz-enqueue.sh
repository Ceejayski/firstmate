#!/usr/bin/env bash
# One short poll of the configured Buzz bridge channel for research requests
# (the firstmate-side intake for the dual-home Grok-research convention; see
# docs/buzz-bridge.md).
#
# Recognized message shapes (case-insensitive, leading whitespace tolerated):
#   fm research: <question>
#   fm: scout web <question>
#
# Output contract: silence when there is nothing new; otherwise one line per
# newly seen request:
#   buzz-research <event_id> <question>
# The question is flattened to one line and truncated to 300 characters.
# Firstmate treats each line as ordinary scout intake: dispatch per the
# configured dispatch rules (web/X-central research runs on Grok when quota
# allows, else the configured Claude research profile), acknowledge via
# fm-buzz-status.sh --text, and post the findings back the same way.
#
# Cursor: state/buzz-bridge.cursor holds the highest created_at already seen,
# so repeat invocations only surface new requests. --peek reads without
# advancing the cursor.
#
# Inert by default, mirroring fm-buzz-status.sh: no configured channel is a
# hard no-op (exit 0, no output); a configured channel with a missing key,
# missing jq, missing CLI, or a failed relay read prints one stderr diagnostic
# and still exits 0, so polling can never fail the fleet.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-buzz-lib.sh
. "$SCRIPT_DIR/fm-buzz-lib.sh"

PEEK=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --peek) PEEK=1; shift ;;
    -h|--help)
      sed -n '2,27p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "fm-buzz-enqueue: unknown argument: $1" >&2; exit 2 ;;
  esac
done

fmb_load_config
[ -n "$FMB_CHANNEL" ] || exit 0
command -v jq >/dev/null 2>&1 || { echo "fm-buzz-enqueue: jq not found; skipping poll" >&2; exit 0; }
if [ -z "$FMB_KEY" ]; then
  echo "fm-buzz-enqueue: BUZZ_BRIDGE_CHANNEL is set but BUZZ_PRIVATE_KEY is not; skipping poll (see docs/buzz-bridge.md)" >&2
  exit 0
fi
if ! command -v "$FMB_BIN" >/dev/null 2>&1; then
  echo "fm-buzz-enqueue: buzz CLI not found ($FMB_BIN); skipping poll (see docs/buzz-bridge.md)" >&2
  exit 0
fi

CURSOR_FILE="$STATE/buzz-bridge.cursor"
SINCE=$(cat "$CURSOR_FILE" 2>/dev/null) || SINCE=""
case "$SINCE" in
  ''|*[!0-9]*) SINCE=0 ;;
esac

FETCH_ARGS=(messages get --channel "$FMB_CHANNEL" --limit 50)
if [ "$SINCE" -gt 0 ]; then
  FETCH_ARGS+=(--since "$SINCE")
fi
if ! BODY=$(fmb_fetch "${FETCH_ARGS[@]}" 2>/dev/null); then
  echo "fm-buzz-enqueue: relay poll failed; will retry on the next invocation" >&2
  exit 0
fi

MAXTS=$(printf '%s' "$BODY" | jq -r '[.[].created_at? // 0] | max // 0' 2>/dev/null) || MAXTS=""
case "$MAXTS" in
  ''|*[!0-9]*)
    echo "fm-buzz-enqueue: unexpected relay response shape; will retry on the next invocation" >&2
    exit 0
    ;;
esac

# Client-side since-filter on top of the relay's --since, so an ignored or
# inclusive relay filter can never re-surface an already-seen request.
printf '%s' "$BODY" | jq -r --argjson since "$SINCE" '
  [ .[]
    | select((.created_at? // 0) > $since)
    | select(.content? | type == "string")
    | select(.content | test("^\\s*fm(\\s+research:|:\\s*scout\\s+web\\b)"; "i")) ]
  | sort_by(.created_at)
  | .[]
  | (.content
      | sub("^\\s*fm\\s+research:\\s*"; ""; "i")
      | sub("^\\s*fm:\\s*scout\\s+web\\s*"; ""; "i")
      | gsub("\\s+"; " ")
      | .[0:300]) as $q
  | "buzz-research \(.id) \($q)"
' 2>/dev/null

if [ -z "$PEEK" ] && [ "$MAXTS" -gt "$SINCE" ]; then
  [ -d "$STATE" ] || mkdir -p "$STATE"
  printf '%s\n' "$MAXTS" > "$CURSOR_FILE"
fi
