#!/usr/bin/env bash
# fm-limit-sense.sh - name a provider quota death from the session TRANSCRIPT,
# not the pane.
#
# Why this exists: one provider limit stops every worker, the orchestrator and
# the watcher within seconds, and a limit death does NOT fire the harness
# turn-end hook. The fleet therefore goes blind at exactly the moment it needs
# to see, and a worker whose quota reset hours ago keeps sitting there. The pane
# banner cannot fix that - the process that would read the pane is a casualty of
# the same event, and the banner text is version-, locale- and width-fragile.
#
# The transcript row is the durable machine signal. Claude Code writes a
# per-session JSONL transcript under
# ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/<cwd-slug>/<session-uuid>.jsonl,
# and a limit death is a structurally distinct assistant row whose
# message.model is the literal "<synthetic>". That row survives the pane, the
# session and the orchestrator, so detection does not have to be running at the
# moment of death.
#
#   fm-limit-sense.sh <task-id> [--pipeline|--no-pipeline]
#
# prints exactly one line and ALWAYS exits 0 on a read (exit 2 only on a usage
# error, so a caller can never be broken by a sensor):
#
#   limit: <none|dead|recovered|unknown> [· class=<limit|transient|auth>]
#          [· since=<ts>] [· reset=<ts>] [· pipeline=recover-custody]
#          [· harness=<h>]
#
#   none       no limit death in this task's newest transcript, or the newest
#              synthetic row is a benign harness meta message
#   dead       the last synthetic row is a real death and nothing ran after it
#   recovered  a real death, but non-synthetic assistant activity follows it
#   unknown    not a claude task, no transcript, no jq, or an unrecognized row -
#              the sensor never guesses, and never makes things worse than the
#              behavior that exists without it
#
# THE TWO-PART PREDICATE IS MANDATORY. `model == "<synthetic>"` alone is NOT a
# limit: `No response requested.` is the most common synthetic message on the
# whole fleet (44 occurrences against 299 total in the captured sample), so a
# bare synthetic-row check reports healthy workers as dead. `<synthetic>`
# narrows to a small, stable, machine-typed set; the text (corroborated by the
# row's own error/apiErrorStatus fields when the text is unrecognized) then
# classifies WITHIN that set. A classification miss degrades to `unknown`, never
# to a false `dead`.
#
# Detection only. This script sends nothing to any agent, resumes nothing, and
# writes nothing anywhere - not even under state/. Auto-resume is a separate,
# captain-held decision.
#
# Harness coverage is an explicit per-harness adapter, never a fleet-wide
# assumption: claude is verified, every other harness reports `unknown`.
#
# The optional pipeline field is the stranded-validation case: when a task is
# limit-dead, `no-mistakes axi sync --check` (read-only; never the bare command,
# which would move HEAD) is consulted once, and `pipeline=recover-custody` is
# reported when the run's commits are stranded and custody has to be returned.
# `--no-pipeline` skips that subprocess for cheap hot-path callers;
# `--pipeline` forces it on a `recovered` task too.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

SEP=' · '
# Bound the read-only pipeline-custody subprocess so a wedged CLI can never
# stall a supervisor that is only asking a question.
NM_TIMEOUT=${FM_LIMIT_SENSE_NM_TIMEOUT:-10}
case "$NM_TIMEOUT" in ''|*[!0-9]*) NM_TIMEOUT=10 ;; esac

print_help() {
  sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'
}

ID=
PIPELINE=auto
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) print_help; exit 0 ;;
    --pipeline) PIPELINE=always ;;
    --no-pipeline) PIPELINE=never ;;
    -*) echo "fm-limit-sense.sh: unknown option: $1" >&2; exit 2 ;;
    *) [ -n "$ID" ] && { echo "fm-limit-sense.sh: unexpected argument: $1" >&2; exit 2; }; ID=$1 ;;
  esac
  shift
done
[ -n "$ID" ] || { echo "usage: fm-limit-sense.sh <task-id> [--pipeline|--no-pipeline]" >&2; exit 2; }

META="$STATE/$ID.meta"

# Emit the one canonical line and exit 0. Every field after the verdict is
# optional and is appended only when it was actually established.
VERDICT=unknown
CLASS=
SINCE=
RESET=
PIPELINE_FIELD=
HARNESS=
emit() {
  local line="limit: $VERDICT"
  [ -n "$CLASS" ] && line="$line${SEP}class=$CLASS"
  [ -n "$SINCE" ] && line="$line${SEP}since=$SINCE"
  [ -n "$RESET" ] && line="$line${SEP}reset=$RESET"
  [ -n "$PIPELINE_FIELD" ] && line="$line${SEP}pipeline=$PIPELINE_FIELD"
  [ -n "$HARNESS" ] && line="$line${SEP}harness=$HARNESS"
  printf '%s\n' "$line"
  exit 0
}

meta_value() {  # <key>
  grep "^$1=" "$META" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# --- adapter selection ------------------------------------------------------

[ -f "$META" ] || emit
HARNESS=$(meta_value harness)
[ -n "$HARNESS" ] || HARNESS=unknown
# Per-harness adapter, deliberately not a fleet-wide assumption: only claude's
# transcript schema is verified. codex writes rollout files carrying live
# rate_limits telemetry and is the obvious next adapter, but its exhaustion
# representation has never been sampled, so guessing here would be exactly the
# false-confidence this sensor exists to avoid.
[ "$HARNESS" = claude ] || emit

WT=$(meta_value worktree)
[ -n "$WT" ] || emit
# The DIRECTORY is deliberately not required to exist: the transcript outlives
# the worktree, so a torn-down task can still be explained.

command -v jq >/dev/null 2>&1 || emit

# --- transcript resolution --------------------------------------------------

# Verified against all 155 transcript directories on this machine: the slug is
# the absolute cwd with '/', '.' and '_' each replaced by '-'.
slug=$(printf '%s' "$WT" | tr '/._' '---')
PROJECTS_DIR=${FM_CLAUDE_PROJECTS_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects}
TDIR="$PROJECTS_DIR/$slug"
[ -d "$TDIR" ] || emit

# Newest top-level transcript by mtime. Subagent transcripts live in a
# <session-uuid>/subagents/ subdirectory and are deliberately not considered:
# this sensor reports the state of the task's own session.
TFILE=
for f in "$TDIR"/*.jsonl; do
  [ -f "$f" ] || continue
  if [ -z "$TFILE" ] || [ "$f" -nt "$TFILE" ]; then
    TFILE=$f
  fi
done
[ -n "$TFILE" ] || emit

# --- part one of the predicate: the last synthetic assistant row ------------

LINENO_SYN=$(grep -nE '"model":[[:space:]]*"<synthetic>"' "$TFILE" 2>/dev/null | tail -1 | cut -d: -f1)
if [ -z "$LINENO_SYN" ]; then
  # A transcript with no synthetic row at all is a clean session.
  VERDICT=none
  emit
fi

ROW=$(sed -n "${LINENO_SYN}p" "$TFILE" 2>/dev/null)
[ -n "$ROW" ] || emit

# One jq pass yields the four fields the classifier needs, tab separated, so a
# malformed row degrades to `unknown` instead of failing the caller.
FIELDS=$(printf '%s' "$ROW" | jq -r '
  select((.type == "assistant") and (.message.model == "<synthetic>"))
  | [ ([.message.content[]? | select(.type == "text") | .text] | join(" ")),
      (.timestamp // ""),
      (.error // ""),
      (.apiErrorStatus // "" | tostring),
      (.isApiErrorMessage // false | tostring) ]
  | @tsv' 2>/dev/null) || FIELDS=
[ -n "$FIELDS" ] || emit

IFS=$(printf '\t') read -r TEXT TS ERRKIND ERRSTATUS ISERR <<EOF
$FIELDS
EOF

# --- part two of the predicate: classify WITHIN the synthetic set -----------

# Order matters. The auth family carries an "API Error:" tail
# ("Please run /login · API Error: 403 ...") and must be recognized before the
# transient family claims it.
classify_text() {  # <text> -> limit|transient|auth|benign|unrecognized
  case "$1" in
    "No response requested."*)
      printf 'benign' ;;
    *"/login"*)
      printf 'auth' ;;
    *"You've hit your"*limit*|*"You've reached your"*limit*|\
    *"out of usage credits"*|*"Usage credits are required"*|\
    *"include usage credits"*|*"out of usage"*)
      printf 'limit' ;;
    "API Error:"*|*"API Error:"*)
      printf 'transient' ;;
    *)
      printf 'unrecognized' ;;
  esac
}

# Corroboration for a row whose text this version does not recognize. The
# message family is large and drifting across CLI versions, but these fields are
# machine-typed and were stable across every captured sample, so an unrecognized
# rate_limit row is still correctly a limit rather than silently `unknown`.
classify_structural() {  # -> limit|transient|auth|benign|unrecognized
  case "$ERRKIND" in
    rate_limit)            printf 'limit'; return ;;
    authentication_failed) printf 'auth'; return ;;
    server_error)          printf 'transient'; return ;;
  esac
  case "$ERRSTATUS" in
    429)     printf 'limit'; return ;;
    401|403) printf 'auth'; return ;;
    5??)     printf 'transient'; return ;;
  esac
  # A synthetic row that is not an API error at all is a harness meta message,
  # the same structural shape as `No response requested.`.
  if [ "$ISERR" != true ] && [ -z "$ERRKIND" ]; then
    printf 'benign'
    return
  fi
  printf 'unrecognized'
}

KIND=$(classify_text "$TEXT")
[ "$KIND" = unrecognized ] && KIND=$(classify_structural)

case "$KIND" in
  benign)
    # THE critical regression: the most common synthetic message on the fleet
    # reports `none`, never `dead`.
    VERDICT=none
    emit
    ;;
  limit|transient|auth) ;;
  *)
    # Recognized as neither benign nor a known death: say so honestly.
    emit
    ;;
esac

CLASS=$KIND
case "$TS" in
  *T*Z) SINCE=${TS%%.*}Z ;;
  '')   SINCE= ;;
  *)    SINCE=$TS ;;
esac

# --- death or recovery ------------------------------------------------------

# Real activity means a later assistant row from a real model. A queued user
# message alone does not prove recovery - it can be typed into a session that
# dies again on the same limit - so only actual model output counts.
if tail -n "+$((LINENO_SYN + 1))" "$TFILE" 2>/dev/null \
  | grep -E '"type":[[:space:]]*"assistant"' \
  | grep -qvE '"model":[[:space:]]*"<synthetic>"'; then
  VERDICT=recovered
else
  VERDICT=dead
fi

# --- reset time -------------------------------------------------------------

# Both captured forms, resolved to an absolute UTC instant so a caller can
# compare it against `date -u +%Y-%m-%dT%H:%M:%SZ` as a plain string:
#   session limit · resets <h>[:<mm>]<am|pm> (<TZ>)
#   weekly  limit · resets <Mon> <d> at <h>[:<mm>]<am|pm> (<TZ>)
#
# Build-vs-adopt, evaluated before writing this: the hard part - the IANA zone
# database, DST rules and their history - is NOT hand-rolled. It is delegated to
# `Intl.DateTimeFormat`, the platform's maintained CLDR/ICU implementation, and
# node is already a required common tool (bin/fm-bootstrap.sh COMMON_TOOLS).
# Three alternatives were considered and rejected on evidence:
#   - `Temporal.ZonedDateTime.from(...)` would express this in one call, and is
#     the right answer the day it lands: verified undefined on this machine's
#     node v24.18.0, so it cannot be depended on yet.
#   - luxon / date-fns-tz would mean introducing an npm dependency tree into a
#     toolbelt that deliberately has none (no package.json, no node_modules in
#     bin/), and a sensor whose whole contract is "never fail the caller" must
#     not start failing on a home that has not run an install.
#   - GNU `date -d 'TZ="..." ...'` does exactly this in one shot but is
#     GNU-only; BSD date on macOS cannot, and this fleet runs on macOS.
# What remains local is the standard two-pass inversion of a forward-only
# formatter, which is the same technique those libraries use internally when
# Temporal is absent: read the zone offset AT the naive guess, correct by it,
# then re-read the offset at the corrected instant and correct once more. Two
# passes suffice because a second correction can only be needed when the first
# guess landed on the far side of a transition, and the corrected instant is
# then within that transition's own offset of the target.
#
# If node is missing or the string does not parse, the reset field is omitted -
# never guessed.
RESET_JS='
const text = process.env.FM_LS_TEXT || "";
const deathIso = process.env.FM_LS_TS || "";
const death = new Date(deathIso);
if (isNaN(death.getTime())) process.exit(0);
const MON = {jan:1,feb:2,mar:3,apr:4,may:5,jun:6,jul:7,aug:8,sep:9,oct:10,nov:11,dec:12};
let mo = 0, day = 0, hh, mm, ap, tz;
let m = text.match(/resets\s+([A-Za-z]{3,9})\s+(\d{1,2})\s+at\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)\s*\(([^)]+)\)/i);
if (m) { mo = MON[m[1].slice(0,3).toLowerCase()] || 0; day = +m[2]; hh = +m[3]; mm = m[4] ? +m[4] : 0; ap = m[5].toLowerCase(); tz = m[6].trim(); }
else {
  m = text.match(/resets\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)\s*\(([^)]+)\)/i);
  if (!m) process.exit(0);
  hh = +m[1]; mm = m[2] ? +m[2] : 0; ap = m[3].toLowerCase(); tz = m[4].trim();
}
if (hh === 12) hh = 0;
if (ap === "pm") hh += 12;
let fmt;
try {
  fmt = new Intl.DateTimeFormat("en-US", {timeZone: tz, hour12: false,
    year: "numeric", month: "2-digit", day: "2-digit",
    hour: "2-digit", minute: "2-digit", second: "2-digit"});
} catch (e) { process.exit(0); }
function parts(ms) {
  const o = {};
  for (const p of fmt.formatToParts(new Date(ms))) if (p.type !== "literal") o[p.type] = p.value;
  return o;
}
function offset(ms) {
  const p = parts(ms);
  return Date.UTC(+p.year, +p.month - 1, +p.day, (+p.hour) % 24, +p.minute, +p.second) - ms;
}
function wall(y, mth, d, h, mi) {
  const naive = Date.UTC(y, mth - 1, d, h, mi, 0);
  let g = naive - offset(naive);
  return naive - offset(g);
}
const t = death.getTime();
let out = null;
if (mo) {
  const y0 = +parts(t).year;
  for (const y of [y0, y0 + 1]) { const c = wall(y, mo, day, hh, mm); if (c >= t) { out = c; break; } }
  if (out === null) out = wall(y0, mo, day, hh, mm);
} else {
  const p = parts(t);
  out = wall(+p.year, +p.month, +p.day, hh, mm);
  if (out < t) { const p2 = parts(t + 86400000); out = wall(+p2.year, +p2.month, +p2.day, hh, mm); }
}
process.stdout.write(new Date(out).toISOString().replace(/\.\d{3}Z$/, "Z") + "\n");
'
if [ "$CLASS" = limit ] && [ -n "$TS" ] && command -v node >/dev/null 2>&1; then
  RESET=$(FM_LS_TEXT="$TEXT" FM_LS_TS="$TS" node -e "$RESET_JS" 2>/dev/null | head -1) || RESET=
  case "$RESET" in
    *T*Z) ;;
    *) RESET= ;;
  esac
fi

# --- stranded pipeline ------------------------------------------------------

# A validation run killed mid-flight leaves its commits in the local gate with
# custody unreturned. `--check` is the read-only plan: it changes nothing, and
# the bare command is never used here because it would move HEAD.
want_pipeline_check() {
  case "$PIPELINE" in
    never)  return 1 ;;
    always) [ "$VERDICT" = dead ] || [ "$VERDICT" = recovered ] ;;
    *)      [ "$VERDICT" = dead ] ;;
  esac
}

nm_sync_check() {
  [ -d "$WT" ] || return 1
  command -v no-mistakes >/dev/null 2>&1 || return 1
  if command -v timeout >/dev/null 2>&1; then
    ( cd "$WT" && timeout "$NM_TIMEOUT" no-mistakes axi sync --check ) 2>/dev/null
  elif command -v gtimeout >/dev/null 2>&1; then
    ( cd "$WT" && gtimeout "$NM_TIMEOUT" no-mistakes axi sync --check ) 2>/dev/null
  else
    ( cd "$WT" && no-mistakes axi sync --check ) 2>/dev/null
  fi
}

if want_pipeline_check && [ "$(meta_value kind)" != scout ]; then
  if nm_sync_check | grep -qE '^[[:space:]]*code:[[:space:]]*"?recover_custody"?[[:space:]]*$'; then
    PIPELINE_FIELD=recover-custody
  fi
fi

emit
