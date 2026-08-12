#!/usr/bin/env bash
# fm-review-brief.sh - compose an independent reviewer brief from the standing
# review-check specification (sections 3–5 and 9 of the brain's standing spec).
#
# Replaces hand-written per-PR review briefs. Inputs are machine-readable:
#   state/<ticket>.meta (pr=, pr_head=, project=, changed_paths=, required_stages=)
#   claim / stage / sha (passed or read from ready marker)
#   optional data/review-spec/<project>.md (captain-private registry)
#   optional prior reports under data/ linked from the ticket status
#
# Does not invent a second check scheme. The universal core (U1–U6), base/
# collision checks (B1–B3, B7), and stage catalogs (CR/QA/SEC) below are the
# standing catalog; surface flags filter conditional checks.
#
# Usage:
#   fm-review-brief.sh <ticket-id> <stage> [--sha SHA] [--claimer ID]
#                      [--state DIR] [--pipeline-dir DIR] [--out PATH]
#                      [--pr URL]
# Prints the brief path on success. Exit 0 ok, 1 refuse, 2 usage.
#
# Layer-2 diff-content stage selection is a separately ticketed ship — this
# composer filters checks by path-layer flags only. Post-merge build (B4) is
# merge-agent work, not reviewer brief content beyond noting it exists later.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PIPELINE_DIR="${FM_PIPELINE_DIR_OVERRIDE:-${FM_HOME}/state/pipeline}"

# shellcheck source=bin/fm-pipeline-lib.sh
. "$SCRIPT_DIR/fm-pipeline-lib.sh"
# shellcheck source=bin/fm-ready-check.sh
. "$SCRIPT_DIR/fm-ready-check.sh"

TICKET=
STAGE=
SHA=
CLAIMER=
OUT=
PR=
PROJECT_NAME=

while [ "$#" -gt 0 ]; do
  case "$1" in
    --sha) SHA=$2; shift 2 ;;
    --claimer) CLAIMER=$2; shift 2 ;;
    --state) STATE=$2; shift 2 ;;
    --pipeline-dir) PIPELINE_DIR=$2; shift 2 ;;
    --out) OUT=$2; shift 2 ;;
    --pr) PR=$2; shift 2 ;;
    -h|--help)
      sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*)
      echo "usage: fm-review-brief.sh <ticket-id> <stage> [options]" >&2
      exit 2
      ;;
    *)
      if [ -z "$TICKET" ]; then
        TICKET=$1
      elif [ -z "$STAGE" ]; then
        STAGE=$1
      else
        echo "usage: fm-review-brief.sh <ticket-id> <stage> [options]" >&2
        exit 2
      fi
      shift
      ;;
  esac
done

if [ -z "$TICKET" ] || [ -z "$STAGE" ]; then
  echo "usage: fm-review-brief.sh <ticket-id> <stage> [options]" >&2
  exit 2
fi

case "$STAGE" in
  code-review|qa|security-review) ;;
  *)
    echo "error: unknown stage $STAGE" >&2
    exit 2
    ;;
esac

META="$STATE/$TICKET.meta"
[ -f "$META" ] || { echo "error: no meta for $TICKET" >&2; exit 1; }

[ -n "$PR" ] || PR=$(fm_ready_meta_pr "$META")
[ -n "$SHA" ] || SHA=$(fm_ready_meta_pr_head "$META")
if [ -z "$SHA" ] && [ -f "$PIPELINE_DIR/$TICKET.ready" ]; then
  SHA=$(fm_ready_field "$PIPELINE_DIR" "$TICKET" sha 2>/dev/null || true)
fi
if [ -z "$SHA" ] || ! fm_pr_head_valid "$SHA"; then
  echo "error: no valid PR head SHA for $TICKET" >&2
  exit 1
fi
if [ -z "$PR" ]; then
  echo "error: no PR URL for $TICKET" >&2
  exit 1
fi

PROJ_ABS=$(grep '^project=' "$META" 2>/dev/null | tail -1 | cut -d= -f2- || true)
if [ -n "$PROJ_ABS" ]; then
  PROJECT_NAME=$(basename "$PROJ_ABS")
else
  PROJECT_NAME=unknown
fi

PATHS=$(grep '^changed_paths=' "$META" 2>/dev/null | tail -1 | cut -d= -f2- || true)
REQUIRED=$(grep '^required_stages=' "$META" 2>/dev/null | tail -1 | cut -d= -f2- || true)
if [ -z "$REQUIRED" ]; then
  if [ -z "$PATHS" ]; then
    # Last chance: derive from the live git diff rather than greening generic stages.
    if ! fm_pipeline_record_changed_paths "$STATE" "$TICKET" >/dev/null; then
      echo "error: no changed_paths/required_stages for $TICKET and could not derive them" >&2
      exit 1
    fi
    PATHS=$(grep '^changed_paths=' "$META" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    REQUIRED=$(grep '^required_stages=' "$META" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  else
    if ! REQUIRED=$(fm_pipeline_required_stages "$PATHS"); then
      echo "error: could not derive required stages for $TICKET" >&2
      exit 1
    fi
  fi
fi
if [ -z "$REQUIRED" ]; then
  echo "error: required stages still empty for $TICKET" >&2
  exit 1
fi

# Surface flags from path layer (layer-2 diff content is a later ship).
FLAG_MONEY=0
FLAG_UI=0
FLAG_COPY=0
FLAG_SERVER=0
FLAG_DOCS_ONLY=0
if [ -n "$PATHS" ]; then
  lower_paths=$(printf '%s' "$PATHS" | tr '[:upper:]' '[:lower:]')
  if printf '%s' "$lower_paths" | grep -Eqi "$FM_PIPELINE_SECURITY_RE"; then
    FLAG_MONEY=1
  fi
  if printf '%s' "$lower_paths" | grep -Eqi '\.(tsx|jsx|css|html|vue)($| )|/(components|routes|public)/'; then
    FLAG_UI=1
  fi
  if printf '%s' "$lower_paths" | grep -Eqi "$FM_PIPELINE_DOCS_RE"; then
    FLAG_COPY=1
  fi
  if printf '%s' "$lower_paths" | grep -Eqi '(^| )(server|api|routes)/'; then
    FLAG_SERVER=1
  fi
  if [ "$(fm_pipeline_required_stages "$PATHS")" = "code-review" ]; then
    FLAG_DOCS_ONLY=1
  fi
fi

IMPLEMENTER=$(fm_pipeline_implementer_id "$STATE" "$TICKET")
[ -n "$CLAIMER" ] || CLAIMER=$(fm_pipeline_reviewer_task_id "$TICKET" "$STAGE")

if [ -z "$OUT" ]; then
  OUT="$DATA/$CLAIMER/brief.md"
fi
mkdir -p "$(dirname "$OUT")"

REGISTRY=
if [ -f "$DATA/review-spec/${PROJECT_NAME}.md" ]; then
  REGISTRY="$DATA/review-spec/${PROJECT_NAME}.md"
fi

# Prior review reports: ticket status may point at data/<id>/report.md paths.
PRIOR_REPORTS=
if [ -f "$STATE/$TICKET.status" ]; then
  while IFS= read -r line; do
    case "$line" in
      *data/*/report.md*)
        r=$(printf '%s' "$line" | grep -o 'data/[^ ]*/report.md' | head -1 || true)
        [ -n "$r" ] && PRIOR_REPORTS="${PRIOR_REPORTS:+$PRIOR_REPORTS }$r"
        ;;
    esac
  done < "$STATE/$TICKET.status"
fi

TITLE=$TICKET
if [ -f "$DATA/$TICKET/brief.md" ]; then
  # First non-empty non-heading line of implementer brief as title seed.
  TITLE=$(grep -m1 -E '^[^#[:space:]]' "$DATA/$TICKET/brief.md" 2>/dev/null | head -c 200 || true)
  [ -n "$TITLE" ] || TITLE=$TICKET
fi

{
  cat <<EOF
# Task
Independently review ${PROJECT_NAME} PR ${PR} at head ${SHA} — ${TITLE} — and return a
${STAGE} verdict. You did not write this, and the author does not get to certify it.
Ticket: ${TICKET}. Claimer / reviewer id: ${CLAIMER}. Implementer id: ${IMPLEMENTER:-unknown}.
Required stages for this ticket: ${REQUIRED}.
Changed paths: ${PATHS:-unknown}.

You are a crewmate managed by firstmate. Work on your own; do not wait for a human.
Append status only for supervisor-actionable events on **this review task's** status
file. When the review is complete, append the verdict line to the **ticket** status
(\`state/${TICKET}.status\`) using the exact format in "Report the verdict", write
the full findings report to \`data/${CLAIMER}/report.md\`, then append
\`done: review ${STAGE} for ${TICKET}\` on your own status.

## Why this exists
This brief is composed mechanically from the standing review-check specification
(universal core, stage catalog, base/collision checks). It replaces hand-written
per-PR review briefs.

Read the ticket implementer brief when present: \`data/${TICKET}/brief.md\`.
Carry the captain's words and the claimed defect/deliverable from that ticket.

## Read first
Prior pass reports (confirm not regressed; do not re-litigate what they proved correct):
${PRIOR_REPORTS:-none recorded on ticket status}

Verified-correct list from earlier passes: confirm still true; attack what is new.

## Base and collisions FIRST
Run these before any other stage check (the #89 lesson: a verdict against a stale base is worthless).

- **B1 — Bind to the live head first (U1).** Resolve the PR's current head at the forge
  and compare with claim SHA \`${SHA}\`. Mismatch → release the claim (or report
  stale), do not review a SHA nobody can merge.
- **B2 — Bind the base.** Record the merge-target SHA you judged against as \`[base=<sha>]\`
  in the verdict.
- **B3 — Merged result must build.** Merge/rebase the PR head onto the current merge
  target in the review worktree; build it; run the suite on the merged tree.
  Fast-forward heads record \`built=ff\`. "Merges cleanly" is not the bar.
- **B7 — Collision statement.** Name open PRs on the same repo whose changed paths
  intersect yours; state semantic collision or independence and a safe landing order.
  "No text conflict" is insufficient.

## Universal core (every stage, no exceptions)
- **U1** Live head bind (above).
- **U2** Independence: you did not write this; do not ask the author to run your checks.
  Author counts are claims. Implementer id \`${IMPLEMENTER:-missing}\` must differ from you.
- **U3** Evidence rule: never cite an artifact you cannot inspect. Tool success messages
  are not evidence (screenshot tools have reported a path and written no file).
- **U4** Attack, don't only read. Construct the failure.
- **U5** Verdict is MERGE / DO NOT MERGE / CANNOT VERIFY → green / red / cannot-verify.
- **U6** Must-nots: do not fix, do not push, do not merge, never \`git stash\` (shared
  across worktrees). On money repos: never touch \`.env\` or wallet material; never
  print a key or seed. Captain-owned decisions → \`needs-decision:\` on the ticket, not a verdict.

## Your stage's checks
EOF

  case "$STAGE" in
    code-review)
      cat <<'EOF'
### code-review — is the change what it claims, and do its guards guard?

- **CR1 — Base and merged build** (unconditional): B1–B3 first.
- **CR2 — Honest suite counts** (unconditional): run `bin/fm-honest-done.sh --solo`
  from the review worktree — full suite on PR head and on current merge target, one
  at a time, never concurrently, both SHAs printed, failures labelled
  branch-introduced or inherited. If solo cannot be asserted: **CANNOT VERIFY**.
  Do not accept the author's counts.
- **CR3 — Prove the guards detect** (unconditional): for each named guard/test the PR
  relies on, break the guarded code, watch the *named* test fail, restore, watch it
  pass. A test that passes before and after proves nothing.
- **CR4 — Test realism** (unconditional): does the test drive the real event, or call
  the handler directly? Process-restart / provider-switch / wire claims need real
  construction or an honest "doesn't" in the report.
- **CR8 — Dead code and lying comments** (unconditional): deleted means deleted.
EOF
      if [ "$FLAG_SERVER" -eq 1 ] || [ "$FLAG_MONEY" -eq 1 ]; then
        cat <<'EOF'
- **CR5 — Business logic on the server** (SERVER/MONEY): the server must still refuse;
  browser hard-coding of prices/amounts is not authority.
EOF
      fi
      if [ "$FLAG_MONEY" -eq 1 ]; then
        cat <<'EOF'
- **CR6 — No fabricated zeros, code path** (MONEY): unread values render unknown, never `0`.
- **CR7 — A retryable fault is not a verdict** (MONEY/SERVER): timeout/unreachable stay
  distinct from refusal.
EOF
      fi
      ;;
    qa)
      cat <<'EOF'
### qa — does the product do what the ticket says, under attack?

- **QA1 — Reproduce the claimed defect on base, verify it's gone on head** (fix tickets).
- **QA2 — The adjacency attack set** (unconditional): from the ticket's claim, construct:
  1. repeat/restart  2. partial completion  3. race  4. crash mid-transaction
  5. corrupt/missing input  6. identity switch mid-flight  7. dependency down.
  Record each result, pass or fail.
EOF
      if [ "$FLAG_MONEY" -eq 1 ]; then
        cat <<'EOF'
- **QA3 — Wire capture on money paths** (MONEY): capture actual request bodies; copy is not evidence.
- **QA5 — Units** (MONEY/COPY): product unit language; no raw base-unit numbers without scale.
- **QA7 — Fabricated zeros, rendered** (MONEY/UI): disconnect/fault then read the screen.
EOF
      fi
      if [ "$FLAG_COPY" -eq 1 ] || [ "$FLAG_UI" -eq 1 ]; then
        cat <<'EOF'
- **QA4 — Copy truthfulness** (COPY/UI): nothing promises what the product cannot do.
  List claims verified (`claims=<n>` in the verdict).
EOF
      fi
      if [ "$FLAG_UI" -eq 1 ]; then
        cat <<'EOF'
- **QA6 — Both themes, mobile, offline** (UI): theme via the product's real mechanism
  (often `data-theme`, not only `prefers-color-scheme`); mobile 390×844; offline renders
  degraded honestly.
EOF
      fi
      ;;
    security-review)
      cat <<'EOF'
### security-review — can anyone act with authority they don't hold?

- **SEC1 — Enumerate authority state, attack the class** (unconditional in this stage):
  sessions, signatures, bearers, tokens, caches, refs, order/claim state — what clears
  or re-checks each on identity change. Any authority state with no clearer is a finding.
- **SEC4 — Fail-open on unreadable identity** (unconditional): unreadable principal → refuse, not pass.
- **SEC6 — Secrets hygiene** (unconditional): no key, seed, bearer, or token in diffs, logs, fixtures.
EOF
      if [ "$FLAG_MONEY" -eq 1 ] || [ "$FLAG_UI" -eq 1 ]; then
        cat <<'EOF'
- **SEC2 — Mid-flight and idle identity switch** (MONEY/session UI): A→B mid-request, idle, A→B→A.
EOF
      fi
      if [ "$FLAG_MONEY" -eq 1 ]; then
        cat <<'EOF'
- **SEC3 — Replay and forgery** (MONEY): capture and re-fire signatures/invoices/sessions.
- **SEC5 — Server holds the decision** (MONEY+SERVER): browser never selects spend authority.
EOF
      fi
      ;;
  esac

  cat <<EOF

## Standing traps / project registry
Surface flags for this ticket: MONEY=${FLAG_MONEY} UI=${FLAG_UI} COPY=${FLAG_COPY} SERVER=${FLAG_SERVER} DOCS_ONLY=${FLAG_DOCS_ONLY}.
EOF

  if [ -n "$REGISTRY" ]; then
    echo "Project registry (read fully): \`$REGISTRY\`"
    echo
    cat "$REGISTRY"
    echo
  else
    cat <<EOF
No project registry at \`data/review-spec/${PROJECT_NAME}.md\`. Use fleet defaults:
firstmate shared tracked material follows firstmate-coding-guidelines; money repos
never touch wallet material; theme/units caveats live in the project when known.
EOF
  fi

  cat <<EOF

## Verification
CR2 / honest suite measurement is mandatory at code-review for this SHA; later stages
on the same sha+base may inherit measured counts. Name known inherited failures rather
than rerunning until green.

There is **no CI** on these repos. Your own green is not a merge verdict; the merge
gate requires independent stage greens at the live head.

## Report the verdict
Write findings to \`data/${CLAIMER}/report.md\`.

Append **one** line to \`state/${TICKET}.status\` (exact format, no spaces inside brackets):

\`\`\`
verdict: green|red|cannot-verify [sha=${SHA}] [stage=${STAGE}] [by=${CLAIMER}] [findings=<n>] [base=<merge-target-sha>] [branch=<pass>p<fail>f] [target=<pass>p<fail>f] [failset=byte-identical|branch-introduced|unverified|contended] [built=merged|ff|no] [claims=<n>]
\`\`\`

- green → MERGE at this stage for this SHA
- red → DO NOT MERGE; ticket returns to implementer
- cannot-verify → escalate (needs-decision); never guess

## Must not
- Do not fix, push, or merge.
- Never \`git stash\`.
- Do not widen authority: ask-user / product / money / public-claim decisions →
  \`needs-decision:\` on the ticket, not a silent green.
- Do not restart the shared no-mistakes daemon.
- Never \`pkill -f bin/fm-watch.sh\`.

## Setup
You are in a disposable worktree of the project under review. Verify isolation before
branching. Review is read-only relative to the PR: no ship commits of your own.

## Definition of done
Report written, verdict line appended to the ticket status, \`done: review ${STAGE} for ${TICKET}\`
on your status. Stop. Firstmate's pipeline tick applies the verdict.
EOF
} > "$OUT"

printf '%s\n' "$OUT"
exit 0
