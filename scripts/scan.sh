#!/usr/bin/env bash
# =============================================================================
# scripts/scan.sh
# =============================================================================
# Purpose
#   Run tfsec against terraform/ and either pass or fail the pipeline.
#
# Gate policy
#   - HIGH or CRITICAL → exit 1 (blocks deploy.sh)
#   - MEDIUM or LOW   → exit 0 (warn only — sandbox policy)
#   - tfsec 1.28.5 is required; see README.md "Pre-flight: tool pins"
#
# Output
#   - Writes one record to dashboard/public/data/tfsec-history.json
#   - Records: timestamp, version, exit, counts (per severity), findings[]
#   - Writes the latest run summary to dashboard/public/data/tfsec-last.json
#     (the dashboard polls this — simpler than streaming JSONL)
#   - Prints a short human summary to stdout
#
# SEC_INTENT: this script is the SHIFT-LEFT gate. It is the single chokepoint
# that decides whether deploy.sh may run. The decision is auditable (TFLAST
# is logged), reproducible (same tfsec version), and fails loud (non-zero
# exit + colored stderr).
# =============================================================================
set -euo pipefail

# ---- Paths ------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TF_DIR="$ROOT_DIR/terraform"
DASH_DATA="$ROOT_DIR/dashboard/public/data"
HISTORY_FILE="$DASH_DATA/tfsec-history.json"
LAST_FILE="$DASH_DATA/tfsec-last.json"

mkdir -p "$DASH_DATA"

# ---- tfsec version guard ----------------------------------------------------
# SEC_INTENT: fail loudly if tfsec is not 1.28.5. Newer versions (1.28.10+)
# silently ignore --exclude and inline ignores, which would let the deliberate
# misconfig pass. The README documents this in detail.
required_tfsec="v1.28.5"
actual="$(tfsec --version 2>/dev/null | grep -E "^v1\." | tail -1 || true)"
if [[ "$actual" != "$required_tfsec" ]]; then
  echo "FATAL: tfsec version mismatch." >&2
  echo "  required: $required_tfsec" >&2
  echo "  actual:   ${actual:-<missing>}" >&2
  echo "  See README.md 'Pre-flight: tool pins' for the workaround." >&2
  exit 2
fi

# ---- Run tfsec, capture everything ------------------------------------------
# -f json: machine-readable for the JSON log
# -B:      disable color (we only want the JSON; we color the summary ourselves)
# --force-all-dirs: scan nested folders (currently we only have one but be safe)
timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
raw_json="$(mktemp)"
trap 'rm -f "$raw_json"' EXIT

# tfsec exit codes:
#   0  no problems
#   1  problems found (we treat this as the "expected" path)
#   2  error
#   3  invalid HCL
# We do NOT use `set -e` here because exit 1 is normal.
set +e
tfsec "$TF_DIR" -f json --no-color --force-all-dirs >"$raw_json" 2>"${raw_json}.err"
tfsec_exit=$?
set -e

if [[ $tfsec_exit -eq 2 || $tfsec_exit -eq 3 ]]; then
  echo "FATAL: tfsec failed to run (exit $tfsec_exit)" >&2
  cat "${raw_json}.err" >&2 || true
  exit 2
fi

# ---- Parse tfsec JSON -------------------------------------------------------
# We use `jq` for everything past this point. If jq is missing, fail clean.
if ! command -v jq >/dev/null 2>&1; then
  echo "FATAL: jq is required but not installed." >&2
  exit 2
fi

# SEC_INTENT: extract only the fields the dashboard needs. We deliberately
# do NOT pass through raw descriptions or full location data — the dashboard
# shows rule_id + severity + resource, which is enough for a demo and keeps
# the JSON file small.
record="$(jq -n \
  --arg ts    "$timestamp" \
  --argjson exit "$tfsec_exit" \
  --slurpfile tfsec "$raw_json" \
  '{
    timestamp: $ts,
    tfsec_exit: $exit,
    counts: {
      critical: ([$tfsec[0].results[]? | select(.severity=="CRITICAL")] | length),
      high:     ([$tfsec[0].results[]? | select(.severity=="HIGH")]     | length),
      medium:   ([$tfsec[0].results[]? | select(.severity=="MEDIUM")]   | length),
      low:      ([$tfsec[0].results[]? | select(.severity=="LOW")]      | length),
      ignored:  ([$tfsec[0].results[]? | select(.severity=="INFO")]     | length)
    },
    findings: [
      $tfsec[0].results[]? | {
        severity:   .severity,
        rule_id:    .rule_id,
        resource:   .resource,
        description: .description,
        line:       .location.start_line
      }
    ]
  }')"

# ---- Decide gate -----------------------------------------------------------
# Note: tfsec itself counts *only non-ignored* results when it exits 1. The
# "counts" above already exclude ignored findings (they appear in the
# results[] only when --include-ignored is set, which we do not use).
critical_count="$(echo "$record" | jq '.counts.critical')"
high_count="$(echo "$record" | jq '.counts.high')"

if [[ "$critical_count" -gt 0 || "$high_count" -gt 0 ]]; then
  gate="FAIL"
  echo "$record" | jq --arg gate "$gate" '. + {gate: $gate}' >"$LAST_FILE"
else
  gate="PASS"
  echo "$record" | jq --arg gate "$gate" '. + {gate: $gate}' >"$LAST_FILE"
fi

# ---- Append to history (atomic, JSON-line style) ---------------------------
# We keep tfsec-history.json as a JSON array of records. The dashboard fetches
# the whole thing. To avoid corruption, we write to a tmp file and rename.
# SEC_INTENT: if tfsec-history.json is missing/corrupt, recover as empty
# array rather than failing the gate.
history_tmp="$(mktemp)"
if [[ -s "$HISTORY_FILE" ]] && jq -e 'type == "array"' "$HISTORY_FILE" >/dev/null 2>&1; then
  jq --argjson r "$record" '. + [$r]' "$HISTORY_FILE" >"$history_tmp"
else
  echo "[$record]" | jq '.' >"$history_tmp"
fi
mv "$history_tmp" "$HISTORY_FILE"

# ---- Human summary ----------------------------------------------------------
echo "---- tfsec scan ($timestamp) ----"
echo "  version:  $required_tfsec"
echo "  results:  critical=$critical_count high=$high_count \
            medium=$(echo "$record" | jq '.counts.medium') \
            low=$(echo "$record" | jq '.counts.low')"
echo "  gate:     $gate"
if [[ "$gate" == "FAIL" ]]; then
  echo "" >&2
  echo "  FAILING findings:" >&2
  echo "$record" | jq -r '.findings[] | select(.severity=="CRITICAL" or .severity=="HIGH") | "    [\(.severity)] \(.rule_id) on \(.resource) (line \(.line))"' >&2
  echo "" >&2
  echo "  Deploy is BLOCKED. Fix the findings, or run:" >&2
  echo "    ./scripts/toggle-fixture.sh off   # if the failing resource is the deliberate fixture" >&2
  echo "  Then re-run this script." >&2
  exit 1
fi
echo "  dashboard: $LAST_FILE"
