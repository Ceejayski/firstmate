#!/usr/bin/env bash
# fm-model-probe.sh - on-demand model-entitlement probe for the Qwen harness.
#
# Why this exists: configured is not entitled. The captain's ~/.qwen/settings.json
# lists model ids the CLI will *try*; only a live call tells you whether the
# current account can actually use them. A routing edit that names a denied id
# dispatches real work into a 403. This script is the cheap measurement that
# keeps the routing table honest.
#
# On demand only. One trivial API call per configured id. Never wired into
# session start, bootstrap, spawn, or any automatic path - operators run it
# before changing config/crew-dispatch.json and when a dispatch dies on a model
# error.
#
# Usage:
#   fm-model-probe.sh
#   fm-model-probe.sh --model <id>
#   fm-model-probe.sh --settings <path> --timeout <seconds>
#   fm-model-probe.sh -h | --help
#
# Reads model ids from the harness settings file (default:
# ${QWEN_HOME:-$HOME/.qwen}/settings.json). The settings file's own shape is
# the authority: under modelProviders, every object that carries a non-empty
# string "id" is a candidate, across every provider key. If the file is missing,
# unreadable, not JSON, or has no extractable ids under that shape, prints one
# line of unknown and exits 0 - never crashes, never invents an id list.
#
# For each id, issues one headless probe:
#   QWEN_CODE_SUPPRESS_YOLO_WARNING=1 <qwen> -m <id> -p <probe-prompt>
# with a per-call wall-clock bound (default 100s, matching the investigation that
# first measured this fleet's split). The bound comes from perl alarm, then
# timeout, then gtimeout - whichever the host has. Only a host with none of the
# three degrades to an unbounded call. Serial by design; do not add concurrency
# here unless a measured full pass is actually too slow for operators.
#
# Prints exactly one line per model (or one unknown line when no ids could be
# listed), then exits 0. Denial is data, not failure - exit non-zero only for
# usage errors (unknown flag / bad --timeout):
#
#   <id> <entitled|denied|unknown> [· latency=<s>] [· error=<text>]
#
# Verdicts:
#   entitled  the model's own stdout carries the sentinel word PROBEOK and no
#             denial marker appears on either stream. Denial always wins: a
#             refusal payload that quotes the probe prompt back is not an
#             entitlement.
#   denied    the provider refused the model (access denied / model not exist /
#             a 403 or 404 in status context / not eligible / forbidden and
#             kin); error= carries the provider's own text, not a paraphrase
#   unknown   missing CLI, timeout with no PROBEOK, unparseable settings, or
#             any other outcome that is not a clear entitle or deny
#
# Hard safety:
#   - NEVER prints, logs, or echoes an API key or any credential value from the
#     settings file. Candidate secret strings collected while parsing are
#     scrubbed from every printed error field. Env-var NAMES are not secrets and
#     are left intact so provider errors that name a missing variable stay
#     actionable.
#   - NEVER writes the settings file (or any other credential file). Read only.
#   - NEVER auto-edits config/crew-dispatch.json. This tool measures; humans
#     and firstmate decide routing.
#
# Environment / overrides (tests and operators):
#   QWEN_HOME                 settings directory (default: $HOME/.qwen)
#   FM_MODEL_PROBE_SETTINGS   absolute path to settings file (wins over QWEN_HOME)
#   FM_MODEL_PROBE_TIMEOUT    per-model wall-clock seconds (default: 100)
#   FM_MODEL_PROBE_QWEN       qwen executable path or name (default: qwen on PATH)
#   FM_MODEL_PROBE_WORKDIR    directory the probe runs in (default: a fresh temp
#                             dir under ${TMPDIR:-/tmp}, removed on exit)
#
# Flags:
#   --settings <path>   same as FM_MODEL_PROBE_SETTINGS for this invocation
#   --timeout <seconds> same as FM_MODEL_PROBE_TIMEOUT for this invocation
#   --model <id>        probe only this id (still requires a parseable settings
#                       file that lists it; unknown if the id is not configured)
#   -h, --help          print this header and exit 0
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# SCRIPT_DIR retained for future FM_ROOT-relative helpers; this tool is
# intentionally home/settings-scoped rather than repo-scoped.
: "${SCRIPT_DIR}"

SEP=' · '
DEFAULT_TIMEOUT=100
PROBE_PROMPT='Reply with exactly the word PROBEOK and nothing else.'
SENTINEL='PROBEOK'

print_help() {
  sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'
}

die_usage() {
  printf 'fm-model-probe: %s\n' "$*" >&2
  exit 2
}

# Collapse output to a single line and drop control characters so the operator
# line format stays one line per model even when the CLI dumps a stack.
sanitize_one_line() {
  # tr -d deletes CR/LF/tabs; then squeeze spaces.
  printf '%s' "$1" | tr -d '\r\n\t' | tr -s ' ' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

# Scrub every known secret string out of free text before it is printed.
# secrets_file is one secret per line (exact values collected from settings).
scrub_secrets() {
  local text=$1 secrets_file=$2 line
  if [ -n "$secrets_file" ] && [ -f "$secrets_file" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      [ -n "$line" ] || continue
      # Skip trivially short values that would over-redact (env key NAMES are
      # not secrets; values under a few chars are not useful key material).
      if [ "${#line}" -lt 8 ]; then
        continue
      fi
      text=${text//"$line"/'<redacted>'}
    done < "$secrets_file"
  fi
  printf '%s' "$text"
}

# Extract the provider's own error text from a probe's combined stdout+stderr.
# Prefer an API Error line when present; otherwise the first non-empty,
# non-yolo-warning line; otherwise the whole scrubbed blob.
extract_error_text() {
  local raw=$1 line preferred=
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|*'running headless with --yolo'*|*'QWEN_CODE_SUPPRESS_YOLO_WARNING'*) continue ;;
    esac
    case "$line" in
      *'API Error:'*|*'Access to model denied'*|*'Model not exist'*)
        preferred=$line
        break
        ;;
    esac
    if [ -z "$preferred" ]; then
      preferred=$line
    fi
  done <<EOF
$raw
EOF
  if [ -z "$preferred" ]; then
    preferred=$raw
  fi
  sanitize_one_line "$preferred"
}

# True when the text carries a provider refusal marker. Status codes are only
# a refusal in status context - a bare 403/404 also matches request ids and
# trace tokens, which would drop a healthy model out of routing.
has_denial_marker() {
  case "$1" in
    *'Access to model denied'*|*'Model not exist'*|*'not eligible'*|*'not authorized'*|*'Forbidden'*|*'forbidden'*)
      return 0
      ;;
    *'API Error: 403'*|*'API Error: 404'*|*'status 403'*|*'status 404'*|*'status code 403'*|*'status code 404'*|*'HTTP 403'*|*'HTTP 404'*|*'404 Not Found'*)
      return 0
      ;;
  esac
  return 1
}

# Classify a probe response into entitled|denied|unknown.
# out_raw is the model's own stdout; raw is stdout+stderr combined.
# Prints: <verdict>\t<error-or-empty>
classify_raw() {
  local out_raw=$1 raw=$2 timed_out=$3
  # Provider refusals - match on the shapes this fleet has actually seen and
  # close kin. Keep the raw text for the error= field; do not paraphrase.
  # Checked before the sentinel: a refusal payload that echoes the probe prompt
  # (which contains PROBEOK) is a denial, not an entitlement.
  if has_denial_marker "$raw"; then
    printf 'denied\t%s\n' "$(extract_error_text "$raw")"
    return 0
  fi
  case "$out_raw" in
    *"$SENTINEL"*)
      printf 'entitled\t\n'
      return 0
      ;;
  esac
  if [ "$timed_out" = 1 ]; then
    printf 'unknown\t%s\n' "timeout after ${TIMEOUT}s with no ${SENTINEL}"
    return 0
  fi
  if [ -z "$raw" ]; then
    printf 'unknown\t%s\n' "empty probe response"
    return 0
  fi
  printf 'unknown\t%s\n' "$(extract_error_text "$raw")"
}

print_result_line() {
  local id=$1 verdict=$2 latency=$3 err=$4
  local out
  out="$id $verdict"
  if [ -n "$latency" ]; then
    out+="${SEP}latency=${latency}s"
  fi
  if [ -n "$err" ]; then
    out+="${SEP}error=${err}"
  fi
  printf '%s\n' "$out"
}

# Parse settings: write model ids (one per line) to ids_file, secret values to
# secrets_file. Exit status 0 with empty ids_file means "parsed but no ids";
# exit status 1 means missing/unreadable/unparseable - caller prints unknown.
parse_settings() {
  local settings=$1 ids_file=$2 secrets_file=$3
  if [ ! -f "$settings" ]; then
    return 1
  fi
  if [ ! -r "$settings" ]; then
    return 1
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    return 1
  fi
  # python exits 0 on successful parse (even with zero ids); non-zero on
  # JSON/shape failure. It never prints secret values - only ids and a separate
  # secrets stream on fd 3.
  python3 - "$settings" "$ids_file" "$secrets_file" <<'PY'
import json, sys, os

settings_path, ids_path, secrets_path = sys.argv[1], sys.argv[2], sys.argv[3]

try:
    with open(settings_path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    sys.exit(1)

if not isinstance(data, dict):
    sys.exit(1)

ids = []
secrets = []

# Keys whose value is the NAME of an env var, not credential material. The
# value under env[name] is the actual secret and is collected separately, so
# redacting the name here would only hide the provider's own diagnostic
# ("environment variable X is not set") from the operator.
NAME_ONLY_KEYS = {"envKey", "apiKeyEnvVar", "apiKeyEnv", "tokenEnv"}


def walk_secrets(obj):
    if isinstance(obj, dict):
        for k, v in obj.items():
            if k in NAME_ONLY_KEYS:
                continue
            lk = str(k).lower()
            if isinstance(v, str) and v and any(
                s in lk for s in ("key", "token", "secret", "password", "auth", "credential")
            ):
                secrets.append(v)
            else:
                walk_secrets(v)
    elif isinstance(obj, list):
        for item in obj:
            walk_secrets(item)

walk_secrets(data)

env = data.get("env")
if isinstance(env, dict):
    for v in env.values():
        if isinstance(v, str) and v:
            secrets.append(v)

providers = data.get("modelProviders")
if providers is None:
    # Expected key absent: treat as unparseable-for-ids rather than inventing
    # another schema. Empty id list with success would look like "no models
    # configured"; missing schema is unknown.
    sys.exit(1)
if not isinstance(providers, dict):
    sys.exit(1)

seen = set()
for _provider, entries in providers.items():
    if not isinstance(entries, list):
        continue
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        mid = entry.get("id")
        if isinstance(mid, str):
            mid = mid.strip()
            if mid and mid not in seen:
                seen.add(mid)
                ids.append(mid)

with open(ids_path, "w", encoding="utf-8") as f:
    for mid in ids:
        f.write(mid + "\n")

with open(secrets_path, "w", encoding="utf-8") as f:
    # Dedup secrets; longest first so scrubbing prefers full key material.
    for s in sorted(set(secrets), key=lambda x: (-len(x), x)):
        f.write(s + "\n")

sys.exit(0)
PY
}

# Which wall-clock bound this host can enforce. perl alarm is the method the
# original investigation measured with and stays first; timeout/gtimeout are the
# same ladder the rest of bin/ uses. `none` is an unbounded best-effort call and
# only happens on a host carrying none of the three.
probe_bound() {
  if command -v perl >/dev/null 2>&1; then
    printf 'perl\n'
  elif command -v timeout >/dev/null 2>&1; then
    printf 'timeout\n'
  elif command -v gtimeout >/dev/null 2>&1; then
    printf 'gtimeout\n'
  else
    printf 'none\n'
  fi
}

run_one_probe() {
  local id=$1
  local start end latency raw out_raw err_raw timed_out=0 verdict err scrubbed
  local out_file err_file rc=0
  # Export once for the child process; subshells inherit it (shellcheck SC2030/31).
  export QWEN_CODE_SUPPRESS_YOLO_WARNING=1

  out_file=$(mktemp "${TMPDIR:-/tmp}/fm-model-probe-out.XXXXXX")
  err_file=$(mktemp "${TMPDIR:-/tmp}/fm-model-probe-err.XXXXXX")
  start=$(date +%s)

  # Bound the wall clock so one hung provider cannot stall the whole serial pass.
  # Critically: the child's stdin must NOT be the model-id list. The outer
  # loop reads ids from a redirected file; an inherited stdin lets qwen (or
  # any child) drain the remaining ids and silently drop them from the run.
  # Streams stay separate: the sentinel only counts on the model's own stdout.
  case "$PROBE_BOUND" in
    perl)
      (
        cd "$WORKDIR" || exit 1
        perl -e 'alarm shift; exec @ARGV' "$TIMEOUT" "$QWEN_BIN" -m "$id" -p "$PROBE_PROMPT" </dev/null
      ) >"$out_file" 2>"$err_file"
      rc=$?
      # 142 = 128 + SIGALRM on many systems; also treat 14 / timeout-ish as timed out
      if [ "$rc" -eq 142 ] || [ "$rc" -eq 14 ]; then
        timed_out=1
      fi
      ;;
    timeout|gtimeout)
      (
        cd "$WORKDIR" || exit 1
        "$PROBE_BOUND" "$TIMEOUT" "$QWEN_BIN" -m "$id" -p "$PROBE_PROMPT" </dev/null
      ) >"$out_file" 2>"$err_file"
      rc=$?
      # 124 = timeout's own signal that the budget was hit; 137 = 128 + SIGKILL.
      if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
        timed_out=1
      fi
      ;;
    *)
      # No bound available on this host: best-effort unbounded call. The
      # post-hoc latency check below is the only guard left.
      (
        cd "$WORKDIR" || exit 1
        "$QWEN_BIN" -m "$id" -p "$PROBE_PROMPT" </dev/null
      ) >"$out_file" 2>"$err_file"
      rc=$?
      ;;
  esac

  end=$(date +%s)
  latency=$((end - start))
  out_raw=$(cat "$out_file" 2>/dev/null || true)
  err_raw=$(cat "$err_file" 2>/dev/null || true)
  rm -f "$out_file" "$err_file"
  if [ -n "$out_raw" ] && [ -n "$err_raw" ]; then
    raw="$out_raw"$'\n'"$err_raw"
  else
    raw="${out_raw}${err_raw}"
  fi

  # If the wall clock exceeded the budget, treat as timed out even when the
  # shell wrapper did not surface the bound's exit code cleanly.
  if [ "$latency" -ge "$TIMEOUT" ] && [ "$timed_out" = 0 ]; then
    case "$out_raw" in
      *"$SENTINEL"*) : ;;
      *) timed_out=1 ;;
    esac
  fi

  # classify_raw prints verdict\terror (error may be empty)
  IFS=$'\t' read -r verdict err < <(classify_raw "$out_raw" "$raw" "$timed_out")
  scrubbed=$(scrub_secrets "${err:-}" "$SECRETS_FILE")
  scrubbed=$(sanitize_one_line "$scrubbed")
  print_result_line "$id" "$verdict" "$latency" "$scrubbed"
}

# --- argv -------------------------------------------------------------------

SETTINGS="${FM_MODEL_PROBE_SETTINGS:-}"
TIMEOUT="${FM_MODEL_PROBE_TIMEOUT:-$DEFAULT_TIMEOUT}"
ONLY_MODEL=
QWEN_BIN="${FM_MODEL_PROBE_QWEN:-qwen}"

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      print_help
      exit 0
      ;;
    --settings)
      [ $# -ge 2 ] || die_usage "--settings requires a path"
      SETTINGS=$2
      shift 2
      ;;
    --settings=*)
      SETTINGS=${1#--settings=}
      shift
      ;;
    --timeout)
      [ $# -ge 2 ] || die_usage "--timeout requires a positive integer"
      TIMEOUT=$2
      shift 2
      ;;
    --timeout=*)
      TIMEOUT=${1#--timeout=}
      shift
      ;;
    --model)
      [ $# -ge 2 ] || die_usage "--model requires an id"
      ONLY_MODEL=$2
      shift 2
      ;;
    --model=*)
      ONLY_MODEL=${1#--model=}
      shift
      ;;
    --)
      shift
      break
      ;;
    -*)
      die_usage "unknown option: $1"
      ;;
    *)
      die_usage "unexpected argument: $1 (see --help)"
      ;;
  esac
done

case "$TIMEOUT" in
  ''|*[!0-9]*|0)
    die_usage "--timeout must be a positive integer (got: ${TIMEOUT:-empty})"
    ;;
esac

if [ -z "$SETTINGS" ]; then
  SETTINGS="${QWEN_HOME:-$HOME/.qwen}/settings.json"
fi

PROBE_BOUND=$(probe_bound)

# --- workspace for the probe process (never the caller's cwd credentials) ---

WORKDIR="${FM_MODEL_PROBE_WORKDIR:-}"
CLEAN_WORKDIR=0
if [ -z "$WORKDIR" ]; then
  WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-model-probe.XXXXXX")
  CLEAN_WORKDIR=1
fi
# Ensure the work dir exists even when the caller supplied the path.
mkdir -p "$WORKDIR" 2>/dev/null || true

TMP_PARSE=$(mktemp -d "${TMPDIR:-/tmp}/fm-model-probe-parse.XXXXXX")
IDS_FILE="$TMP_PARSE/ids"
SECRETS_FILE="$TMP_PARSE/secrets"
: >"$IDS_FILE"
: >"$SECRETS_FILE"
# Only remove a workdir we created. Never delete a caller-supplied path
# (tests pass a fixture directory; operators may pass a kept workspace).
if [ "$CLEAN_WORKDIR" = 1 ]; then
  trap 'rm -rf "$WORKDIR" "$TMP_PARSE"' EXIT
else
  trap 'rm -rf "$TMP_PARSE"' EXIT
fi

if ! parse_settings "$SETTINGS" "$IDS_FILE" "$SECRETS_FILE"; then
  reason="settings file missing, unreadable, or unparseable: $SETTINGS"
  if [ ! -f "$SETTINGS" ]; then
    reason="settings file missing: $SETTINGS"
  elif [ ! -r "$SETTINGS" ]; then
    reason="settings file unreadable: $SETTINGS"
  else
    reason="settings file unparseable or missing modelProviders shape: $SETTINGS"
  fi
  print_result_line "-" "unknown" "" "$reason"
  exit 0
fi

if [ ! -s "$IDS_FILE" ]; then
  print_result_line "-" "unknown" "" "no model ids found under modelProviders in $SETTINGS"
  exit 0
fi

if ! command -v "$QWEN_BIN" >/dev/null 2>&1 && [ ! -x "$QWEN_BIN" ]; then
  # Still list every configured id so the operator sees the full table; each
  # row is unknown with the same reason. FD 3 keeps stdin free for anything
  # else and matches the live probe loop below.
  while IFS= read -r mid <&3 || [ -n "$mid" ]; do
    [ -n "$mid" ] || continue
    if [ -n "$ONLY_MODEL" ] && [ "$mid" != "$ONLY_MODEL" ]; then
      continue
    fi
    print_result_line "$mid" "unknown" "" "qwen executable not found: $QWEN_BIN"
  done 3< "$IDS_FILE"
  if [ -n "$ONLY_MODEL" ] && ! grep -Fqx -- "$ONLY_MODEL" "$IDS_FILE"; then
    print_result_line "$ONLY_MODEL" "unknown" "" "model id not present in settings: $ONLY_MODEL"
  fi
  exit 0
fi

FOUND_ONLY=0
# Read ids on FD 3 so run_one_probe's children can never drain the list via
# inherited stdin (even with the </dev/null guard inside the child).
while IFS= read -r mid <&3 || [ -n "$mid" ]; do
  [ -n "$mid" ] || continue
  if [ -n "$ONLY_MODEL" ]; then
    if [ "$mid" != "$ONLY_MODEL" ]; then
      continue
    fi
    FOUND_ONLY=1
  fi
  run_one_probe "$mid"
done 3< "$IDS_FILE"

if [ -n "$ONLY_MODEL" ] && [ "$FOUND_ONLY" = 0 ]; then
  print_result_line "$ONLY_MODEL" "unknown" "" "model id not present in settings: $ONLY_MODEL"
fi

exit 0
