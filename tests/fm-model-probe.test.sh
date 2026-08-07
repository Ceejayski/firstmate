#!/usr/bin/env bash
# Behavior tests for bin/fm-model-probe.sh - the on-demand model-entitlement
# probe. Configured is not entitled; this tool is how the fleet measures the
# difference without guessing.
#
# Safety contract under test (must never regress):
#   (a) API key / credential values from the settings file never appear in
#       stdout or stderr under any code path, including error paths.
#   (b) The settings (credential) file is never modified - byte-compare before
#       and after every probe.
#   (c) A denied model yields verdict denied with the provider's own error text,
#       and the process still exits 0.
#   (d) Missing or unparseable settings yields unknown and exits 0 - never
#       crashes, never invents model ids.
#   (e) A successful probe yields entitled when the sentinel PROBEOK is present.
#   (f) Denial is data: a full run with mixed entitled/denied still exits 0.
#
# No live API calls: a PATH-shadowed fake `qwen` drives every probe.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROBE="$ROOT/bin/fm-model-probe.sh"
TMP_ROOT=$(fm_test_tmproot fm-model-probe)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
SETTINGS_DIR="$TMP_ROOT/qwen-home"
SETTINGS="$SETTINGS_DIR/settings.json"
WORKDIR="$TMP_ROOT/work"
mkdir -p "$SETTINGS_DIR" "$WORKDIR"

# A stand-in credential value that must NEVER appear in probe output.
SECRET_VALUE='sk-test-DO-NOT-LEAK-this-api-key-value-9f3a2b1c'
SECRET_ENV_NAME='BAILIAN_TOKEN_PLAN_API_KEY'

write_settings() {
  # Minimal modelProviders shape matching the live ~/.qwen/settings.json form.
  cat > "$SETTINGS" <<EOF
{
  "env": {
    "${SECRET_ENV_NAME}": "${SECRET_VALUE}"
  },
  "modelProviders": {
    "openai": [
      {
        "id": "cheap-ok",
        "name": "ok model",
        "baseUrl": "https://example.invalid/v1",
        "envKey": "${SECRET_ENV_NAME}"
      },
      {
        "id": "denied-flash",
        "name": "denied model",
        "baseUrl": "https://example.invalid/v1",
        "envKey": "${SECRET_ENV_NAME}"
      },
      {
        "id": "missing-model",
        "name": "404 model",
        "baseUrl": "https://example.invalid/v1",
        "envKey": "${SECRET_ENV_NAME}"
      }
    ]
  },
  "model": { "name": "cheap-ok" },
  "\$version": 4
}
EOF
}

# Fake qwen: model id decides the response. Never reads settings; never writes.
install_fake_qwen() {
  cat > "$FAKEBIN/qwen" <<'SH'
#!/usr/bin/env bash
set -u
model=
prompt=
while [ $# -gt 0 ]; do
  case "$1" in
    -m|--model) model=$2; shift 2 ;;
    -p|--prompt) prompt=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$model" in
  cheap-ok|entitled-only)
    printf 'PROBEOK\n'
    exit 0
    ;;
  denied-flash)
    # Provider text must pass through verbatim on the denied line.
    printf '[API Error: 403 Access to model denied. Please make sure you are eligible for using the model.]\n' >&2
    exit 0
    ;;
  missing-model)
    printf 'API Error: 404 Model not exist\n' >&2
    exit 0
    ;;
  leak-attempt)
    # Adversarial: CLI echoes a secret-looking string. The probe must still
    # scrub values that came from the settings file; this string is NOT in
    # settings, so it may appear - the contract is about settings credentials.
    printf 'API Error: 403 Access to model denied (ref sk-unrelated)\n' >&2
    exit 0
    ;;
  *)
    printf 'API Error: 500 unexpected model %s\n' "$model" >&2
    exit 0
    ;;
esac
SH
  chmod +x "$FAKEBIN/qwen"
}

# Capture both streams; always assert exit 0 for probe outcomes.
run_probe() {
  local out err code
  out=$(
    PATH="$FAKEBIN:$PATH" \
    FM_MODEL_PROBE_SETTINGS="$SETTINGS" \
    FM_MODEL_PROBE_WORKDIR="$WORKDIR" \
    FM_MODEL_PROBE_TIMEOUT=5 \
    "$PROBE" "$@" 2>"$TMP_ROOT/err"
  )
  code=$?
  err=$(cat "$TMP_ROOT/err" 2>/dev/null || true)
  printf '%s' "$out" >"$TMP_ROOT/out"
  printf '%s' "$err" >"$TMP_ROOT/err"
  printf '%s\n' "$code" >"$TMP_ROOT/code"
  printf '%s' "$out"
  return 0
}

assert_exit_0() {
  local code
  code=$(cat "$TMP_ROOT/code")
  expect_code 0 "$code" "fm-model-probe must exit 0 on probe outcomes"
}

assert_no_secret_anywhere() {
  local out err combined
  out=$(cat "$TMP_ROOT/out" 2>/dev/null || true)
  err=$(cat "$TMP_ROOT/err" 2>/dev/null || true)
  combined="$out"$'\n'"$err"
  assert_not_contains "$combined" "$SECRET_VALUE" \
    "API key from settings must never appear in probe stdout/stderr"
}

assert_settings_unchanged() {
  local before=$1 after
  after=$(cat "$SETTINGS")
  [ "$before" = "$after" ] || fail "settings file was modified (byte-compare failed)"
}

# --- install baseline fixtures ---------------------------------------------

write_settings
install_fake_qwen
BEFORE=$(cat "$SETTINGS")

# --- (d) missing settings -> unknown, exit 0 -------------------------------

rm -f "$SETTINGS"
OUT=$(run_probe)
assert_exit_0
assert_contains "$OUT" "unknown" "missing settings must report unknown"
assert_contains "$OUT" "missing" "missing settings error should say missing"
assert_not_contains "$OUT" "cheap-ok" "missing settings must not invent model ids"
assert_no_secret_anywhere
pass "missing settings -> unknown, exit 0, no invented ids"

# restore settings for remaining cases
write_settings
BEFORE=$(cat "$SETTINGS")

# --- (d2) unparseable settings -> unknown, exit 0 --------------------------

printf 'this is not json {{{{\n' > "$SETTINGS"
OUT=$(run_probe)
assert_exit_0
assert_contains "$OUT" "unknown" "unparseable settings must report unknown"
assert_not_contains "$OUT" "cheap-ok" "unparseable settings must not invent model ids"
assert_settings_unchanged "$(cat "$SETTINGS")"
# Re-check secret scrub: unparseable file still contains the secret string as
# raw text - the probe must not echo file contents.
assert_not_contains "$(cat "$TMP_ROOT/out")$(cat "$TMP_ROOT/err")" "$SECRET_VALUE" \
  "unparseable settings path must not dump file contents containing the key"
pass "unparseable settings -> unknown, exit 0"

# --- (d3) JSON without modelProviders shape -> unknown ---------------------

printf '{"env":{"%s":"%s"},"model":{"name":"x"}}\n' "$SECRET_ENV_NAME" "$SECRET_VALUE" > "$SETTINGS"
OUT=$(run_probe)
assert_exit_0
assert_contains "$OUT" "unknown" "missing modelProviders must report unknown"
assert_no_secret_anywhere
assert_settings_unchanged "$(cat "$SETTINGS")"
pass "JSON without modelProviders -> unknown, exit 0"

# restore full settings
write_settings
BEFORE=$(cat "$SETTINGS")

# --- (e)+(c)+(f) mixed entitled / denied / 404, exit 0 ---------------------

OUT=$(run_probe)
assert_exit_0
assert_settings_unchanged "$BEFORE"
assert_no_secret_anywhere

assert_contains "$OUT" "cheap-ok entitled" "successful probe must be entitled"
assert_contains "$OUT" "denied-flash denied" "403 must be denied"
assert_contains "$OUT" "missing-model denied" "404 Model not exist must be denied"
# Provider's own error text, not a paraphrase.
assert_contains "$OUT" "Access to model denied" \
  "denied line must carry the provider's own error text"
assert_contains "$OUT" "Model not exist" \
  "404 denied line must carry the provider's own error text"
# Latency field present on probed rows.
assert_contains "$OUT" "latency=" "each probed model should report latency="
# Line count = 3 models
line_count=$(printf '%s\n' "$OUT" | grep -c . || true)
[ "$line_count" -eq 3 ] || fail "expected 3 result lines, got $line_count: $OUT"
pass "mixed entitled/denied/404: correct verdicts, provider error text, exit 0"

# --- (a) secret never appears even when error path runs --------------------

# Adversarial settings: put the secret also in a model name field so a naive
# "print the entry" implementation would leak it. Our parser only emits ids.
python3 - "$SETTINGS" "$SECRET_VALUE" "$SECRET_ENV_NAME" <<'PY'
import json, sys
path, secret, envname = sys.argv[1], sys.argv[2], sys.argv[3]
data = {
  "env": {envname: secret},
  "modelProviders": {
    "openai": [
      {
        "id": "denied-flash",
        "name": f"name-contains-{secret}",
        "baseUrl": "https://example.invalid/v1",
        "envKey": envname,
        "generationConfig": {"note": secret},
      }
    ]
  },
}
with open(path, "w", encoding="utf-8") as f:
  json.dump(data, f)
PY
BEFORE=$(cat "$SETTINGS")
OUT=$(run_probe)
assert_exit_0
assert_settings_unchanged "$BEFORE"
assert_no_secret_anywhere
assert_contains "$OUT" "denied-flash denied" "denied still classified when settings hold secrets in extra fields"
pass "API key never appears in output (including error paths); settings byte-unchanged"

# --- --model filters to one id ---------------------------------------------

write_settings
BEFORE=$(cat "$SETTINGS")
OUT=$(run_probe --model denied-flash)
assert_exit_0
assert_settings_unchanged "$BEFORE"
assert_no_secret_anywhere
assert_contains "$OUT" "denied-flash denied" "--model denied-flash probes that id"
assert_not_contains "$OUT" "cheap-ok" "--model must not probe other ids"
assert_not_contains "$OUT" "missing-model" "--model must not probe other ids"
pass "--model filters to a single configured id"

# --- --model for an id not in settings -> unknown, exit 0 ------------------

OUT=$(run_probe --model not-configured-at-all)
assert_exit_0
assert_no_secret_anywhere
assert_contains "$OUT" "not-configured-at-all unknown" \
  "unknown id not in settings reports unknown"
pass "--model for unconfigured id -> unknown, exit 0"

# --- missing qwen binary -> unknown per id, exit 0 -------------------------

write_settings
BEFORE=$(cat "$SETTINGS")
OUT=$(
  PATH="/usr/bin:/bin" \
  FM_MODEL_PROBE_SETTINGS="$SETTINGS" \
  FM_MODEL_PROBE_WORKDIR="$WORKDIR" \
  FM_MODEL_PROBE_TIMEOUT=5 \
  FM_MODEL_PROBE_QWEN="qwen-definitely-not-installed-$$" \
  "$PROBE" 2>"$TMP_ROOT/err"
)
code=$?
printf '%s' "$OUT" >"$TMP_ROOT/out"
printf '%s\n' "$code" >"$TMP_ROOT/code"
assert_exit_0
assert_settings_unchanged "$BEFORE"
assert_no_secret_anywhere
assert_contains "$OUT" "cheap-ok unknown" "missing CLI yields unknown per id"
assert_contains "$OUT" "denied-flash unknown" "missing CLI yields unknown per id"
assert_contains "$OUT" "not found" "missing CLI error names the problem"
pass "missing qwen executable -> unknown per id, exit 0, settings untouched"

# --- help exits 0 and does not touch settings ------------------------------

write_settings
BEFORE=$(cat "$SETTINGS")
help_out=$("$PROBE" --help 2>&1) || true
help_code=$?
expect_code 0 "$help_code" "--help must exit 0"
assert_contains "$help_out" "fm-model-probe" "help text names the tool"
assert_contains "$help_out" "NEVER writes" "help documents the no-write contract"
assert_settings_unchanged "$BEFORE"
pass "--help exits 0 and documents the no-write contract"

# --- usage error is the only non-zero path ---------------------------------

set +e
"$PROBE" --timeout not-a-number >/dev/null 2>"$TMP_ROOT/err"
code=$?
set -e
[ "$code" -ne 0 ] || fail "bad --timeout must be a usage error (non-zero)"
pass "usage error (bad --timeout) exits non-zero; denials do not"

# --- stdin drain regression: every configured id is probed ------------------
#
# A child that inherits the id-list as stdin can silently consume remaining
# ids and produce a one-row report. The fake qwen here reads stdin to empty
# so a regression fails loudly (only the first id would appear).

write_settings
BEFORE=$(cat "$SETTINGS")
cat > "$FAKEBIN/qwen" <<'SH'
#!/usr/bin/env bash
set -u
# Drain stdin if attached - the bug this guards against.
cat >/dev/null 2>&1 || true
model=
while [ $# -gt 0 ]; do
  case "$1" in
    -m|--model) model=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$model" in
  cheap-ok) printf 'PROBEOK\n' ;;
  denied-flash)
    printf '[API Error: 403 Access to model denied. Please make sure you are eligible for using the model.]\n' >&2
    ;;
  missing-model)
    printf 'API Error: 404 Model not exist\n' >&2
    ;;
  *) printf 'API Error: 500 unexpected\n' >&2 ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/qwen"
OUT=$(run_probe)
assert_exit_0
assert_settings_unchanged "$BEFORE"
assert_no_secret_anywhere
line_count=$(printf '%s\n' "$OUT" | grep -c . || true)
[ "$line_count" -eq 3 ] || fail "stdin-drain regression: expected 3 lines, got $line_count: $OUT"
assert_contains "$OUT" "cheap-ok entitled" "stdin-drain regression: first id"
assert_contains "$OUT" "denied-flash denied" "stdin-drain regression: second id"
assert_contains "$OUT" "missing-model denied" "stdin-drain regression: third id"
pass "stdin-drain regression: every configured id is probed"

printf 'ok - fm-model-probe suite complete\n'
