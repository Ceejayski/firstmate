#!/usr/bin/env bash
# Stream GMGN Pump Alert messages into the deck ingest pipeline.
# @pump_sol_alert is GMGN's public portal; live alerts come from the private
# "Pump Alert - GMGN" channel (id 2115686230) once you've joined via their invite.
#
# Usage: fm-gmgn-tg-watch.sh
#
# Requires gotd/cli `tg` binary at ${TG_BIN:-~/.local/bin/tg} and prior login via
# fm-gmgn-tg-login.sh. Polls Telegram channel every ${TELEGRAM_GMGN_POLL_SEC:-30}s
# and posts to ${DECK_URL:-http://127.0.0.1:4747}/api/trade/gmgn-telegram/ingest,
# falling back to local inbox ${GMGN_TELEGRAM_INBOX} when deck is unavailable.
#
# Environment:
#   TG_BIN                    Path to tg binary (default: ~/.local/bin/tg)
#   TELEGRAM_GMGN_CHANNEL_ID  Channel numeric ID (default: 2115686230)
#   TELEGRAM_GMGN_CHANNEL     Channel label (default: @pump_sol_alert)
#   TELEGRAM_GMGN_POLL_SEC    Poll interval seconds (default: 30)
#   DECK_URL                  Deck ingest endpoint (default: http://127.0.0.1:4747)
#   GMGN_TELEGRAM_INBOX       Fallback inbox path (default: ~/.firstmate-deck/gmgn-telegram-inbox.jsonl)
set -euo pipefail

TG_BIN="${TG_BIN:-${HOME}/.local/bin/tg}"
# Private GMGN pump alert channel (no public @username).
CHANNEL_ID="${TELEGRAM_GMGN_CHANNEL_ID:-2115686230}"
CHANNEL_LABEL="${TELEGRAM_GMGN_CHANNEL:-@pump_sol_alert}"
POLL_SEC="${TELEGRAM_GMGN_POLL_SEC:-30}"
DECK_URL="${DECK_URL:-http://127.0.0.1:4747}"
INBOX="${GMGN_TELEGRAM_INBOX:-${HOME}/.firstmate-deck/gmgn-telegram-inbox.jsonl}"

TG_DIR="$(dirname "${TG_BIN}")"
export PATH="${TG_DIR}:${PATH}"

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required" >&2
  exit 1
fi

if ! "${TG_BIN}" whoami >/dev/null 2>&1; then
  echo "Not logged in. Run: bin/fm-gmgn-tg-login.sh" >&2
  exit 1
fi

mkdir -p "$(dirname "${INBOX}")"

# GNU date takes -d @SECONDS, BSD date takes -r SECONDS; probe a known epoch.
DATE_EPOCH_MODE=""
if [[ "$(date -u -d @0 +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)" == "1970-01-01T00:00:00Z" ]]; then
  DATE_EPOCH_MODE="gnu"
elif [[ "$(date -u -r 0 +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)" == "1970-01-01T00:00:00Z" ]]; then
  DATE_EPOCH_MODE="bsd"
fi

epoch_to_iso() {
  local epoch="$1" out=""
  [[ "${epoch}" =~ ^[0-9]+$ ]] || { date -u +%Y-%m-%dT%H:%M:%SZ; return 0; }
  case "${DATE_EPOCH_MODE}" in
    gnu) out="$(date -u -d "@${epoch}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)" ;;
    bsd) out="$(date -u -r "${epoch}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)" ;;
  esac
  if [[ -z "${out}" ]]; then
    out="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  fi
  printf '%s' "${out}"
}

ingest_text() {
  local text="$1" msg_id="${2:-}" msg_date="${3:-}"
  local ts
  if [[ "${msg_date}" =~ ^[0-9]+$ && "${msg_date}" != "0" ]]; then
    ts="$(epoch_to_iso "${msg_date}")"
  else
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  fi

  if curl -fsS -m 5 -X POST "${DECK_URL}/api/trade/gmgn-telegram/ingest" \
      -H 'Content-Type: application/json' \
      -d "$(jq -nc --arg text "${text}" --arg channel "${CHANNEL_LABEL}" --argjson id "${CHANNEL_ID}" \
        '{text:$text, channel:$channel, channelId:$id}')" >/dev/null 2>&1; then
    echo "${ts} ingested msg=${msg_id:-?} ($(wc -c <<<"${text}" | tr -d ' ') bytes)" >&2
    return 0
  fi

  jq -nc \
    --arg text "${text}" \
    --arg channel "${CHANNEL_LABEL}" \
    --argjson channelId "${CHANNEL_ID}" \
    --arg ts "${ts}" \
    --arg msgId "${msg_id}" \
    '{source:"gmgn_telegram",channel:$channel,channelId:$channelId,at:$ts,messageId:$msgId,text:$text}' \
    >> "${INBOX}"
  echo "${ts} queued to inbox msg=${msg_id:-?} (deck ingest not ready)" >&2
}

fetch_channel_state() {
  "${TG_BIN}" chats list -o json | jq -c --argjson id "${CHANNEL_ID}" '
    .data.chats[]? | select((.peer.id // 0) == $id)
  ' 2>/dev/null | head -1
}

echo "Watching Pump Alert - GMGN (id ${CHANNEL_ID}; portal ${CHANNEL_LABEL})" >&2
echo "Poll every ${POLL_SEC}s → ${DECK_URL}/api/trade/gmgn-telegram/ingest (fallback: ${INBOX})" >&2
echo "Ctrl+C to stop." >&2

last_seen_date=0
last_seen_text=""

# Backfill: don't re-ingest the current last message on cold start unless forced.
state="$(fetch_channel_state || true)"
if [[ -n "${state}" ]]; then
  last_seen_date="$(printf '%s' "${state}" | jq -r '.last_date // 0')"
  last_seen_text="$(printf '%s' "${state}" | jq -r '.last_message // ""')"
  echo "Baseline last_date=${last_seen_date}" >&2
fi

while true; do
  state="$(fetch_channel_state || true)"
  if [[ -z "${state}" ]]; then
    echo "$(date -u +%H:%M:%S) channel ${CHANNEL_ID} not in dialog list — join Pump Alert - GMGN in Telegram" >&2
    sleep "${POLL_SEC}"
    continue
  fi

  cur_date="$(printf '%s' "${state}" | jq -r '.last_date // 0')"
  cur_text="$(printf '%s' "${state}" | jq -r '.last_message // ""')"

  if [[ -n "${cur_text}" && ( "${cur_date}" != "${last_seen_date}" || "${cur_text}" != "${last_seen_text}" ) ]]; then
    ingest_text "${cur_text}" "" "${cur_date}"
    last_seen_date="${cur_date}"
    last_seen_text="${cur_text}"
  fi

  sleep "${POLL_SEC}"
done