#!/usr/bin/env bash
# Start (or restart) interactive Telegram QR login via gotd/cli `tg`.
# Opens a dedicated tmux window when TMUX is set; otherwise runs in foreground.
#
# Usage: fm-gmgn-tg-login.sh
#
# Requires gotd/cli `tg` binary at ${TG_BIN:-~/.local/bin/tg}.
# Install from https://github.com/gotd/cli/releases/latest
#
# Session credentials are stored by the tg binary itself, not in this script.
set -euo pipefail

TG_BIN="${TG_BIN:-${HOME}/.local/bin/tg}"
if [[ ! -x "${TG_BIN}" ]]; then
  echo "tg not found at ${TG_BIN}. Install from https://github.com/gotd/cli/releases/latest" >&2
  exit 1
fi

TG_DIR="$(dirname "${TG_BIN}")"
export PATH="${TG_DIR}:${PATH}"

if ! "${TG_BIN}" init 2>/dev/null; then
  : # config may already exist
fi

if [[ -n "${TMUX:-}" ]]; then
  TG_SESSION="$(tmux display-message -p '#S')"
  if tmux list-windows -t "${TG_SESSION}" -F '#W' 2>/dev/null | grep -qx 'fm-tg-login'; then
    tmux select-window -t "${TG_SESSION}:fm-tg-login"
    echo "Switched to existing fm-tg-login window — scan QR there or re-run tg login inside it."
    exit 0
  fi
  tmux new-window -t "${TG_SESSION}" -n fm-tg-login \
    "export PATH=\"${TG_DIR}:\$PATH\"; echo '=== Telegram login (gotd/cli) ==='; echo 'Phone: Telegram → Settings → Devices → Link Desktop Device'; echo; exec tg login"
  tmux select-window -t "${TG_SESSION}:fm-tg-login"
  echo "Opened fm-tg-login tmux window — switch there and scan the QR code."
else
  echo "=== Telegram login (gotd/cli) ==="
  echo "Phone: Telegram → Settings → Devices → Link Desktop Device"
  echo
  exec "${TG_BIN}" login
fi