#!/usr/bin/env bash
# fm-honest-done.sh - emit one comparable suite-count line for a ship done-report.
#
# Runs the project's discovered test command on the current branch HEAD and on
# the merge target, compares failure name sets, and prints exactly one line:
#
#   <N> pass / <M> fail on branch; <P> pass / <Q> fail on target; failure set <VERDICT>; branch=<sha> target=<sha>
#
# VERDICT is one of:
#   BYTE-IDENTICAL              failure-name sets equal (solo + uncontended only)
#   BRANCH-INTRODUCED: <names>  names present on branch but not target (solo + uncontended)
#   UNVERIFIED                  no --solo / FM_HONEST_DONE_SOLO=1; counts may still print
#   CONTENDED                   competing suite activity detected; do not trust the compare
#
# A comparison verdict (BYTE-IDENTICAL / BRANCH-INTRODUCED) is refused unless the
# operator asserts solo measurement AND no competing suite process is observed.
# A contended or unverified run must not look like a clean baseline: that is the
# failure mode this tool exists to prevent.
#
# or, when no test command can be discovered without guessing:
#
#   unknown
#
# Usage:
#   fm-honest-done.sh --solo [--dir <path>] [--target <ref>]
#   fm-honest-done.sh [--dir <path>] [--target <ref>]
#   fm-honest-done.sh --discover-only [--dir <path>]
#   fm-honest-done.sh -h | --help
#
# Options:
#   --dir <path>     project worktree to measure (default: cwd)
#   --target <ref>   merge-target ref (default: origin/<default-branch> if that
#                    ref exists, else <default-branch>)
#   --solo           operator asserts nothing else is competing for the suite;
#                    required for BYTE-IDENTICAL / BRANCH-INTRODUCED. Also set by
#                    FM_HONEST_DONE_SOLO=1. Disables target-result cache reuse.
#   --discover-only  print the discovered test command (or `unknown`) and exit 0
#                    without running the suite
#   -h, --help       print this header
#
# Discovery (first match wins; never invent a command):
#   1. package.json scripts.test (non-empty string)
#   2. Makefile or makefile target named exactly `test`
#   3. .no-mistakes.yaml or .no-mistakes.yml commands.test (non-empty string)
#   4. .github/workflows/*.{yml,yaml} suite run steps (see discover_from_ci)
#      - bin/fm-test-run.sh --lane portable-* suite jobs are composed in CI order
#      - other explicit suite runners found in run: steps (npm test, etc.)
#      - --check-coverage, --list, --aggregate-json, and herdr-gated lanes are
#        not suite measurement commands and are skipped
#
# Safety:
#   - Refuses a primary checkout (git-dir == common-dir) for measurement runs
#     unless FM_HONEST_DONE_ALLOW_PRIMARY=1 (test harness only). --discover-only
#     is exempt: it reads project files and never runs a suite or touches git.
#   - Never merges, pushes, or checks out either branch in place.
#   - Target runs use a temporary detached worktree that is removed before exit.
#   - Caller's HEAD, branch tip, and working tree (status --porcelain) are
#     snapshotted and must match after the run.
#   - Does not decide merge eligibility; it only reports.
#   - Does not treat missing CI / "no checks configured" as a pass.
#
# Cache:
#   Target results may be reused under ${TMPDIR:-/tmp}/fm-honest-done-cache/
#   keyed by exact target commit SHA + test command, only when not --solo.
#   A commit is immutable, but a cached result may have been taken under
#   contention, so solo runs always re-measure the target. Branch (HEAD) is
#   always run fresh. Set FM_HONEST_DONE_NO_CACHE=1 to force a double run.
#
# Exit status:
#   0  measured line or `unknown` printed
#   2  usage / environment error (not a git worktree, primary refused, etc.)
set -eu

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

die() {
  printf 'fm-honest-done: %s\n' "$*" >&2
  exit 2
}

DIR=
TARGET_REF=
DISCOVER_ONLY=0
SOLO=0
if [ "${FM_HONEST_DONE_SOLO:-}" = 1 ]; then
  SOLO=1
fi
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --dir)
      [ "$#" -gt 1 ] || die "--dir requires a path"
      DIR=$2
      shift 2
      ;;
    --dir=*)
      DIR=${1#--dir=}
      shift
      ;;
    --target)
      [ "$#" -gt 1 ] || die "--target requires a ref"
      TARGET_REF=$2
      shift 2
      ;;
    --target=*)
      TARGET_REF=${1#--target=}
      shift
      ;;
    --solo)
      SOLO=1
      shift
      ;;
    --discover-only)
      DISCOVER_ONLY=1
      shift
      ;;
    -*)
      die "unknown option: $1"
      ;;
    *)
      die "unexpected argument: $1 (use --dir <path>)"
      ;;
  esac
done

if [ -z "$DIR" ]; then
  DIR=$(pwd -P)
else
  DIR=$(cd "$DIR" && pwd -P) || die "cannot cd to --dir path"
fi

git -C "$DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || die "not a git worktree: $DIR"

# Primary checkout = main working tree (git-dir resolves to the same place as
# common-dir). Linked worktrees (crewmate shape) have a distinct git-dir under
# .git/worktrees/<name>.
is_primary_checkout() {
  local root=$1 gd cd_path
  gd=$(git -C "$root" rev-parse --git-dir)
  cd_path=$(git -C "$root" rev-parse --git-common-dir)
  case "$gd" in
    /*) ;;
    *) gd=$(cd "$root" && cd "$gd" && pwd -P) ;;
  esac
  case "$cd_path" in
    /*) ;;
    *) cd_path=$(cd "$root" && cd "$cd_path" && pwd -P) ;;
  esac
  # Also normalize absolute paths that may still be relative-looking after
  # rev-parse on some git versions.
  gd=$(cd "$gd" 2>/dev/null && pwd -P || printf '%s' "$gd")
  cd_path=$(cd "$cd_path" 2>/dev/null && pwd -P || printf '%s' "$cd_path")
  [ "$gd" = "$cd_path" ]
}

if [ "$DISCOVER_ONLY" -eq 0 ] && is_primary_checkout "$DIR"; then
  if [ "${FM_HONEST_DONE_ALLOW_PRIMARY:-}" != 1 ]; then
    die "refusing primary checkout (not a linked worktree): $DIR"
  fi
fi

default_branch() {
  local root=$1 ref branch
  ref=$(git -C "$root" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    printf '%s\n' "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$root" show-ref --verify --quiet "refs/heads/$branch"; then
      printf '%s\n' "$branch"
      return 0
    fi
    if git -C "$root" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
      printf '%s\n' "$branch"
      return 0
    fi
  done
  return 1
}

resolve_target_ref() {
  local root=$1 explicit=$2 def
  if [ -n "$explicit" ]; then
    printf '%s\n' "$explicit"
    return 0
  fi
  def=$(default_branch "$root") || die "cannot determine default branch for $root"
  if git -C "$root" rev-parse --verify --quiet "refs/remotes/origin/$def^{commit}" >/dev/null; then
    printf 'origin/%s\n' "$def"
    return 0
  fi
  if git -C "$root" rev-parse --verify --quiet "refs/heads/$def^{commit}" >/dev/null; then
    printf '%s\n' "$def"
    return 0
  fi
  die "cannot resolve merge target for default branch $def"
}

# Discover a project-declared test command. Never invent one.
discover_test_command() {
  local root=$1 cmd

  if [ -f "$root/package.json" ] && command -v python3 >/dev/null 2>&1; then
    cmd=$(
      python3 - "$root/package.json" <<'PY'
import json, sys
try:
    doc = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(0)
scripts = doc.get("scripts") if isinstance(doc, dict) else None
if not isinstance(scripts, dict):
    sys.exit(0)
val = scripts.get("test")
if isinstance(val, str):
    val = val.strip()
    if val:
        print(val)
PY
    ) || true
    if [ -n "${cmd:-}" ]; then
      printf '%s\n' "$cmd"
      return 0
    fi
  fi

  if [ -f "$root/Makefile" ] || [ -f "$root/makefile" ]; then
    local mf=
    [ -f "$root/Makefile" ] && mf="$root/Makefile"
    [ -z "$mf" ] && [ -f "$root/makefile" ] && mf="$root/makefile"
    # Exact target `test` (optional deps after colon). Ignore .PHONY and comments.
    if awk '
      /^[[:space:]]*#/ { next }
      /^test:([[:space:]]|$)/ { found=1; exit }
      END { exit found ? 0 : 1 }
    ' "$mf"; then
      printf 'make test\n'
      return 0
    fi
  fi

  for nm in "$root/.no-mistakes.yaml" "$root/.no-mistakes.yml"; do
    [ -f "$nm" ] || continue
    cmd=$(
      if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
        python3 - "$nm" <<'PY'
import sys
try:
    import yaml
except Exception:
    sys.exit(0)
doc = yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}
cmds = doc.get("commands") if isinstance(doc, dict) else None
val = cmds.get("test") if isinstance(cmds, dict) else None
if isinstance(val, str):
    val = val.strip()
    if val:
        print(val)
PY
      else
        # Structural fallback: commands.test string under the commands block.
        awk '
          /^commands:[[:space:]]*$/ { in_cmds=1; next }
          in_cmds && /^[^[:space:]#]/ { in_cmds=0 }
          in_cmds && /^[[:space:]]+test:[[:space:]]*/ {
            sub(/^[[:space:]]+test:[[:space:]]*/, "")
            gsub(/^['\''"]|['\''"]$/, "")
            if ($0 != "" && $0 != "~" && $0 != "null") print
            exit
          }
        ' "$nm"
      fi
    ) || true
    if [ -n "${cmd:-}" ]; then
      printf '%s\n' "$cmd"
      return 0
    fi
  done

  if cmd=$(discover_from_ci "$root"); then
    printf '%s\n' "$cmd"
    return 0
  fi

  return 1
}

# Read suite commands declared in GitHub Actions workflows. Emits one command
# string or returns 1. Never invents runners that are not present in a workflow
# run step; only composes multiple portable fm-test-run lanes already declared.
discover_from_ci() {
  local root=$1
  local wf="$root/.github/workflows"
  [ -d "$wf" ] || return 1
  command -v python3 >/dev/null 2>&1 || return 1

  python3 - "$wf" <<'PY'
import re
import sys
from pathlib import Path

wf = Path(sys.argv[1])
blobs = []
for path in sorted(wf.glob("*.yml")) + sorted(wf.glob("*.yaml")):
    try:
        blobs.append(path.read_text(encoding="utf-8", errors="replace"))
    except OSError:
        continue
if not blobs:
    sys.exit(1)

# Collapse YAML line continuations so multi-line run blocks become one line.
blob = re.sub(r"\\\r?\n[ \t]*", " ", "\n".join(blobs))

# --- Firstmate / fm-test-run suite jobs ------------------------------------
# Keep real suite invocations; drop inventory/coverage/list/aggregate helpers
# and the real-Herdr lane (needs a pinned herdr install the portable measure
# does not own).
portable_order = {
    "portable-parallel-1": 0,
    "portable-parallel-2": 1,
    "portable-serial": 2,
}
portable = {}  # lane -> command
fm_all = None
fm_other = []

# Match fm-test-run anywhere in a run step (multi-line body, or `run: bin/...`
# on one line). Do not require start-of-line; YAML often has `- run: ` prefix.
for m in re.finditer(r"((?:\./)?bin/fm-test-run\.sh\b[^\n#]*)", blob):
    raw = m.group(1).strip()
    # Drop artifact flags and trailing shell noise; keep suite selectors.
    raw = re.sub(r"\s+--json(?:=|\s+)\S+", "", raw)
    raw = re.sub(r'\s+--json\s+"[^"]*"', "", raw)
    raw = re.sub(r"\s+--json\s+'[^']*'", "", raw)
    raw = re.sub(r"\s{2,}", " ", raw).strip().rstrip(";|&")
    if re.search(r"--check-coverage\b|--list(?:-|\b)|--aggregate-json\b|--help\b", raw):
        continue
    if re.search(r"--family\s+real-herdr|real-herdr-gated", raw):
        continue
    lane_m = re.search(r"--lane\s+(\S+)", raw)
    if lane_m:
        lane = lane_m.group(1)
        # Prefer the portable partition CI uses for broad regression.
        if lane in portable_order:
            portable[lane] = f"bin/fm-test-run.sh --lane {lane}"
        else:
            fm_other.append(f"bin/fm-test-run.sh --lane {lane}")
        continue
    if re.search(r"--all\b", raw):
        fm_all = "bin/fm-test-run.sh --all"
        continue
    if re.search(r"--family\b|--proven-isolated\b|--changed\b", raw):
        # Normalize to bin/ path form for a stable command string.
        rest = raw.split("fm-test-run.sh", 1)[1].strip()
        fm_other.append(f"bin/fm-test-run.sh {rest}".rstrip())
        continue

if portable:
    # Compose every portable lane CI already declares, in CI partition order.
    # Use ';' so a red first lane still runs the rest (counts stay complete);
    # overall exit is non-zero if any lane failed.
    parts = [portable[k] for k in sorted(portable, key=lambda x: portable_order[x])]
    body = "; ".join(f"{p} || r=1" for p in parts)
    print(f"r=0; {body}; exit $r")
    sys.exit(0)
if fm_all:
    print(fm_all)
    sys.exit(0)
if fm_other:
    # Unique, preserve order.
    seen = []
    for c in fm_other:
        if c not in seen:
            seen.append(c)
    if len(seen) == 1:
        print(seen[0])
    else:
        body = "; ".join(f"{p} || r=1" for p in seen)
        print(f"r=0; {body}; exit $r")
    sys.exit(0)

# --- Generic suite runners declared in CI run steps ------------------------
# Only exact common suite entrypoints that appear in the workflow text.
generics = []
patterns = [
    r"\bnpm\s+test\b(?:\s+--[^\n#]*)?",
    r"\bnpm\s+run\s+test\b(?:\s+--[^\n#]*)?",
    r"\bpnpm\s+(?:run\s+)?test\b(?:\s+--[^\n#]*)?",
    r"\byarn\s+(?:run\s+)?test\b(?:\s+--[^\n#]*)?",
    r"\bbun\s+test\b(?:\s+[^\n#]*)?",
    r"\bmake\s+test\b",
    r"\bpytest\b[^\n#]*",
    r"\bcargo\s+test\b[^\n#]*",
    r"\bgo\s+test\b[^\n#]*",
]
for pat in patterns:
    for m in re.finditer(pat, blob):
        g = re.sub(r"\s{2,}", " ", m.group(0).strip())
        # Trim trailing YAML / comment noise
        g = g.split(" #")[0].strip().rstrip("|").strip()
        if g and g not in generics:
            generics.append(g)

if generics:
    # One clear CI suite command; if several distinct, prefer the first.
    print(generics[0])
    sys.exit(0)

sys.exit(1)
PY
}

# Pull "<N> <word>" out of a Vitest/Jest summary line, e.g. `1 failed` from
# "Tests:  1 failed, 5 passed, 6 total". Uses character-class boundaries only:
# GNU `\b` is unsupported by BSD sed and would silently extract nothing there.
extract_summary_count() {
  local line=$1 word=$2 n
  n=$(printf '%s' "$line" \
    | sed -nE "s/.*[^0-9]([0-9]+)[[:space:]]+${word}([^[:alnum:]_].*)?\$/\1/p" \
    | head -1)
  if [ -z "$n" ]; then
    n=$(printf '%s' "$line" \
      | sed -nE "s/^([0-9]+)[[:space:]]+${word}([^[:alnum:]_].*)?\$/\1/p" \
      | head -1)
  fi
  printf '%s' "$n"
}

# Parse suite output into pass count, fail count, and a sorted unique failure
# name list (one name per line on fd 3 via a temp files protocol).
# Writes: $1.pass $1.fail $1.names (sorted unique failure names)
parse_suite_output() {
  local out_prefix=$1 log_file=$2 exit_code=$3
  local pass=0 fail=0

  : >"$out_prefix.names"

  # Firstmate suite runner markers take priority over inner TAP from each
  # tests/*.test.sh (those scripts print many `ok -` lines that would inflate
  # pass counts if counted as the suite). Sum every FM_TEST_SUMMARY so
  # multi-lane CI compositions (portable-parallel-1 + 2 + serial) count as one.
  if grep -Eq '^FM_TEST_SUMMARY total=' "$log_file" 2>/dev/null; then
    local total failed
    total=0
    failed=0
    while IFS= read -r line; do
      local t f
      t=$(printf '%s' "$line" | sed -n 's/.*total=\([0-9][0-9]*\).*/\1/p')
      f=$(printf '%s' "$line" | sed -n 's/.*failed=\([0-9][0-9]*\).*/\1/p')
      t=${t:-0}
      f=${f:-0}
      total=$((total + t))
      failed=$((failed + f))
    done < <(grep -E '^FM_TEST_SUMMARY total=' "$log_file" || true)
    pass=$((total - failed))
    [ "$pass" -ge 0 ] || pass=0
    fail=$failed
    grep -E '^FM_TEST_END ' "$log_file" 2>/dev/null \
      | awk '/exit=[1-9]/ {
          for (i = 1; i <= NF; i++) {
            if ($i !~ /^(FM_TEST_END|exit=|duration_ms=|gate_skip=)/ && $i !~ /^[0-9]{4}-/) {
              print $i
              break
            }
          }
        }' \
      | LC_ALL=C sort -u >"$out_prefix.names" || true
    printf '%s\n' "$pass" >"$out_prefix.pass"
    printf '%s\n' "$fail" >"$out_prefix.fail"
    return 0
  fi

  # Prefer TAP: ok / not ok lines (standalone TAP suites without FM_TEST_*).
  if grep -Eq '^not ok |^ok ' "$log_file" 2>/dev/null; then
    pass=$(grep -cE '^ok ' "$log_file" 2>/dev/null || true)
    fail=$(grep -cE '^not ok ' "$log_file" 2>/dev/null || true)
    # names: "not ok N - name" or "not ok N name"
    grep -E '^not ok ' "$log_file" 2>/dev/null \
      | sed -E 's/^not ok [0-9]+[[:space:]]*(-[[:space:]]*)?//' \
      | sed -E 's/[[:space:]]*#.*$//' \
      | sed -E 's/[[:space:]]+$//' \
      | awk 'NF { print }' \
      | LC_ALL=C sort -u >"$out_prefix.names" || true
    if [ "$((pass + fail))" -gt 0 ]; then
      printf '%s\n' "$pass" >"$out_prefix.pass"
      printf '%s\n' "$fail" >"$out_prefix.fail"
      return 0
    fi
  fi

  # node --test TAP-ish footer: # tests N / # pass N / # fail N
  if grep -Eq '^# (tests|pass|fail|failed) ' "$log_file" 2>/dev/null; then
    pass=$(grep -E '^# pass ' "$log_file" | tail -1 | awk '{print $3}' || true)
    fail=$(grep -E '^# fail(ed)? ' "$log_file" | tail -1 | awk '{print $3}' || true)
    pass=${pass:-0}
    fail=${fail:-0}
    grep -E '^not ok ' "$log_file" 2>/dev/null \
      | sed -E 's/^not ok [0-9]+[[:space:]]*(-[[:space:]]*)?//' \
      | sed -E 's/[[:space:]]*#.*$//' \
      | awk 'NF { print }' \
      | LC_ALL=C sort -u >"$out_prefix.names" || true
    printf '%s\n' "$pass" >"$out_prefix.pass"
    printf '%s\n' "$fail" >"$out_prefix.fail"
    return 0
  fi

  # Vitest / Jest summary lines.
  #   Tests  1 failed | 3 passed (4)
  #   Test Suites: 1 failed, 2 passed, 3 total
  #   Tests:       1 failed, 5 passed, 6 total
  if grep -Eqi 'Tests?[[:space:]]+[0-9].*passed|Test Suites:|Tests:' "$log_file" 2>/dev/null; then
    local summary
    summary=$(grep -Ei 'Tests?[[:space:]]+[0-9].*passed|Tests:.*passed|Test Suites:' "$log_file" | tail -1 || true)
    # Extract "N failed" and "N passed" if present.
    fail=$(extract_summary_count "$summary" failed)
    pass=$(extract_summary_count "$summary" passed)
    fail=${fail:-0}
    pass=${pass:-0}
    # Vitest failure names: lines with leading FAIL or × / x
    {
      grep -E '^[[:space:]]*(FAIL|×|x)[[:space:]]+' "$log_file" 2>/dev/null || true
      grep -E '^[[:space:]]*● ' "$log_file" 2>/dev/null || true
    } | sed -E 's/^[[:space:]]*(FAIL|×|x|●)[[:space:]]+//' \
      | sed -E 's/[[:space:]]+$//' \
      | awk 'NF { print }' \
      | LC_ALL=C sort -u >"$out_prefix.names" || true
    printf '%s\n' "$pass" >"$out_prefix.pass"
    printf '%s\n' "$fail" >"$out_prefix.fail"
    return 0
  fi

  # Unparsed: honest fall-back from exit status only.
  if [ "$exit_code" -eq 0 ]; then
    pass=1
    fail=0
  else
    pass=0
    fail=1
    printf 'unparsed-suite-failure\n' >"$out_prefix.names"
  fi
  printf '%s\n' "$pass" >"$out_prefix.pass"
  printf '%s\n' "$fail" >"$out_prefix.fail"
}

run_suite_in_dir() {
  local work_dir=$1 cmd=$2 log_file=$3
  local rc=0
  # Run through bash -lc so package.json scripts that assume a shell work, and
  # so a bare `make test` / npm script is not subject to word-splitting surprises
  # beyond what the project already declared.
  (
    cd "$work_dir" || exit 127
    # shellcheck disable=SC2086 # project-declared command string must expand as written
    bash -c "$cmd"
  ) >"$log_file" 2>&1 || rc=$?
  printf '%s\n' "$rc"
}

# Git state the script must not change on the caller's worktree.
fingerprint_caller() {
  local root=$1
  {
    git -C "$root" rev-parse HEAD 2>/dev/null || echo 'NOHEAD'
    git -C "$root" symbolic-ref -q HEAD 2>/dev/null || echo 'DETACHED'
    git -C "$root" status --porcelain=v1
  }
}

sha256_text() {
  local s=$1
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$s" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$s" | sha256sum | awk '{print $1}'
  else
    # Fallback: not cryptographic, only used as a cache key component.
    printf '%s' "$s" | cksum | awk '{print $1}'
  fi
}

# True when another process looks like a suite runner outside our process group.
# Our own fm-test-run children share this script's pgid and are ignored.
# FM_HONEST_DONE_FORCE_CONTENDED=1 forces true (tests only).
suite_contention_detected() {
  local self_pid=$$ self_pgid pid pgid cmd
  if [ "${FM_HONEST_DONE_FORCE_CONTENDED:-}" = 1 ]; then
    return 0
  fi
  self_pgid=$(ps -o pgid= -p "$self_pid" 2>/dev/null | tr -d ' ')
  [ -n "$self_pgid" ] || self_pgid=$self_pid

  # BSD and GNU ps both accept -ax with -o pid=,pgid=,command=
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    # shellcheck disable=SC2086 # word-split pid pgid from ps columns
    set -- $line
    pid=$1
    pgid=$2
    shift 2 2>/dev/null || continue
    cmd=$*
    [ -n "$pid" ] || continue
    [ "$pid" = "$self_pid" ] && continue
    [ "$pgid" = "$self_pgid" ] && continue
    # Match suite runners in the command line (space-padded or bare).
    case "$cmd" in
      *fm-test-run.sh*|*fm-honest-done.sh*|*vitest*|*npm\ test*|*npm\ run\ test*|\
      *pnpm\ test*|*yarn\ test*|*pytest*|*cargo\ test*)
        return 0
        ;;
    esac
  done < <(ps -ax -o pid=,pgid=,command= 2>/dev/null || ps -ax -o pid=,pgid=,command=)

  return 1
}

CACHE_ROOT="${TMPDIR:-/tmp}/fm-honest-done-cache"
TARGET_WT=
TARGET_WT_ADDED=0
WORK=
# shellcheck disable=SC2329 # Registered via trap EXIT below.
cleanup() {
  if [ "$TARGET_WT_ADDED" -eq 1 ] && [ -n "$TARGET_WT" ]; then
    git -C "$DIR" worktree remove --force "$TARGET_WT" >/dev/null 2>&1 || rm -rf "$TARGET_WT"
  fi
  if [ -n "${WORK:-}" ] && [ -d "${WORK:-}" ]; then
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT

TEST_CMD=
if ! TEST_CMD=$(discover_test_command "$DIR"); then
  printf 'unknown\n'
  exit 0
fi

if [ "$DISCOVER_ONLY" -eq 1 ]; then
  printf '%s\n' "$TEST_CMD"
  exit 0
fi

if [ -z "$TARGET_REF" ]; then
  TARGET_REF=$(resolve_target_ref "$DIR" "")
else
  TARGET_REF=$(resolve_target_ref "$DIR" "$TARGET_REF")
fi

TARGET_SHA=$(git -C "$DIR" rev-parse --verify "${TARGET_REF}^{commit}") \
  || die "cannot resolve target ref: $TARGET_REF"
BRANCH_SHA=$(git -C "$DIR" rev-parse --verify "HEAD^{commit}") \
  || die "cannot resolve HEAD in $DIR"

BEFORE_FP=$(fingerprint_caller "$DIR")

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-honest-done.XXXXXX")
BRANCH_LOG="$WORK/branch.log"
TARGET_LOG="$WORK/target.log"
BRANCH_PREFIX="$WORK/branch"
TARGET_PREFIX="$WORK/target"

CONTENDED=0
if suite_contention_detected; then
  CONTENDED=1
fi

# --- branch (always fresh, in place) ---
branch_rc=$(run_suite_in_dir "$DIR" "$TEST_CMD" "$BRANCH_LOG")
parse_suite_output "$BRANCH_PREFIX" "$BRANCH_LOG" "$branch_rc"
BRANCH_PASS=$(cat "$BRANCH_PREFIX.pass")
BRANCH_FAIL=$(cat "$BRANCH_PREFIX.fail")
BRANCH_NAMES="$BRANCH_PREFIX.names"

if suite_contention_detected; then
  CONTENDED=1
fi

# --- target (temp detached worktree; optional SHA+cmd cache) ---
cmd_hash=$(sha256_text "$TEST_CMD")
cache_dir="$CACHE_ROOT/$TARGET_SHA"
cache_file="$cache_dir/$cmd_hash.result"
cache_names="$cache_dir/$cmd_hash.names"
use_cache=0
# Solo measurements never reuse cache: a prior result may have been contended.
if [ "$SOLO" -eq 0 ] && [ "${FM_HONEST_DONE_NO_CACHE:-}" != 1 ] \
  && [ -f "$cache_file" ] && [ -f "$cache_names" ]; then
  # Cache format: pass<TAB>fail on line 1.
  if IFS=$(printf '\t') read -r TARGET_PASS TARGET_FAIL <"$cache_file"; then
    case "$TARGET_PASS$TARGET_FAIL" in
      ''|*[!0-9]*) use_cache=0 ;;
      *)
        use_cache=1
        cp "$cache_names" "$TARGET_PREFIX.names"
        printf '%s\n' "$TARGET_PASS" >"$TARGET_PREFIX.pass"
        printf '%s\n' "$TARGET_FAIL" >"$TARGET_PREFIX.fail"
        ;;
    esac
  fi
fi

if [ "$use_cache" -eq 0 ]; then
  TARGET_WT=$(mktemp -d "${TMPDIR:-/tmp}/fm-honest-done-target.XXXXXX")
  # worktree add requires the path to not exist as a non-empty dir on some
  # gits; mktemp created it empty - remove so add can create it.
  rmdir "$TARGET_WT"
  git -C "$DIR" worktree add --detach "$TARGET_WT" "$TARGET_SHA" >/dev/null 2>&1 \
    || die "failed to add temporary worktree for target $TARGET_SHA"
  TARGET_WT_ADDED=1

  target_rc=$(run_suite_in_dir "$TARGET_WT" "$TEST_CMD" "$TARGET_LOG")
  parse_suite_output "$TARGET_PREFIX" "$TARGET_LOG" "$target_rc"
  TARGET_PASS=$(cat "$TARGET_PREFIX.pass")
  TARGET_FAIL=$(cat "$TARGET_PREFIX.fail")

  if [ "$SOLO" -eq 0 ]; then
    mkdir -p "$cache_dir"
    printf '%s\t%s\n' "$TARGET_PASS" "$TARGET_FAIL" >"$cache_file"
    cp "$TARGET_PREFIX.names" "$cache_names"
  fi

  git -C "$DIR" worktree remove --force "$TARGET_WT" >/dev/null 2>&1 || rm -rf "$TARGET_WT"
  TARGET_WT_ADDED=0
  TARGET_WT=
else
  TARGET_PASS=$(cat "$TARGET_PREFIX.pass")
  TARGET_FAIL=$(cat "$TARGET_PREFIX.fail")
fi

if suite_contention_detected; then
  CONTENDED=1
fi

AFTER_FP=$(fingerprint_caller "$DIR")
if [ "$BEFORE_FP" != "$AFTER_FP" ]; then
  die "git state changed during measurement (HEAD/branch/status must be untouched)"
fi

# Verdict: never emit BYTE-IDENTICAL / BRANCH-INTRODUCED without solo + quiet.
# BYTE-IDENTICAL requires equal failure-name sets (not merely empty introductions).
INTRODUCED=$(LC_ALL=C comm -13 "$TARGET_PREFIX.names" "$BRANCH_NAMES" || true)
if [ "$CONTENDED" -eq 1 ]; then
  SET_LABEL='CONTENDED'
elif [ "$SOLO" -eq 0 ]; then
  SET_LABEL='UNVERIFIED'
elif [ -n "$INTRODUCED" ]; then
  names_joined=$(
    printf '%s\n' "$INTRODUCED" \
      | awk 'BEGIN { ORS = "" } { if (NR > 1) printf ", "; printf "%s", $0 } END { print "" }'
  )
  SET_LABEL="BRANCH-INTRODUCED: $names_joined"
elif cmp -s "$BRANCH_NAMES" "$TARGET_PREFIX.names" 2>/dev/null; then
  SET_LABEL='BYTE-IDENTICAL'
else
  # Sets differ only by target-only failures (branch fixed some ambient reds,
  # or flake asymmetry). That is not BYTE-IDENTICAL; with solo it is still a
  # real observation of "no branch-introduced names", reported without claiming
  # set equality.
  SET_LABEL='BRANCH-INTRODUCED: (none)'
fi

printf '%s pass / %s fail on branch; %s pass / %s fail on target; failure set %s; branch=%s target=%s\n' \
  "$BRANCH_PASS" "$BRANCH_FAIL" "$TARGET_PASS" "$TARGET_FAIL" "$SET_LABEL" \
  "$BRANCH_SHA" "$TARGET_SHA"
exit 0
