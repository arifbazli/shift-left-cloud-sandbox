#!/usr/bin/env bash
# =============================================================================
# scripts/scan.sh
# =============================================================================
# Purpose
#   Run tfsec against terraform/ (AWS) AND terraform/azure/ (Azure) and
#   gate the AWS pipeline on the AWS result only. Azure scanning added
#   2026-08-13: same policy, same audit trail, its own gate file
#   (tfsec-azure-last.json/tfsec-azure-history.json) — but INTENTIONALLY
#   decoupled from this script's own exit code. deploy.sh only ever gates
#   on the AWS result, same reasoning as every other AWS/Azure separation
#   in this repo: an Azure-only fixture should never block an AWS-only
#   deploy. scripts/grow-stack-azure.sh is the one place that reads the
#   Azure gate file.
#
# Gate policy (both trees, independently)
#   - HIGH or CRITICAL → gate FAIL
#   - MEDIUM or LOW   → gate PASS (warn only — sandbox policy)
#   - tfsec 1.28.5 is required; see README.md "Pre-flight: tool pins"
#
# Output
#   - AWS:   dashboard/public/data/tfsec-history.json, tfsec-last.json
#   - Azure: dashboard/public/data/tfsec-azure-history.json,
#            tfsec-azure-last.json
#   - Prints a short human summary for both to stdout/stderr
#
# Exit code
#   Reflects the AWS gate ONLY (critical/high → 1). The Azure gate is
#   reported but never changes this script's exit code — see PURPOSE.
#
# SEC_INTENT: this is the SHIFT-LEFT gate for AWS — the single chokepoint
# deciding whether deploy.sh may run. Auditable (tfsec-last.json),
# reproducible (pinned tfsec version), fails loud. The Azure scan added
# alongside it follows the identical policy and audit trail, just without
# wiring into THIS script's pass/fail signal.
# =============================================================================
set -euo pipefail

# ---- Paths ------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DASH_DATA="$ROOT_DIR/dashboard/public/data"

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

if ! command -v jq >/dev/null 2>&1; then
  echo "FATAL: jq is required but not installed." >&2
  exit 2
fi

# ---- run_scan: scan one terraform tree, write its gate files, echo gate ----
# Args: $1 = terraform dir, $2 = last-file path, $3 = history-file path,
#       $4 = human label. Prints "PASS" or "FAIL" on stdout (nothing
# else) so callers can capture it via $(...) — all human-readable
# diagnostics go to stderr.
# tfsec exit codes: 0 no problems, 1 problems found (expected path),
# 2 error, 3 invalid HCL. We do NOT use `set -e` here because exit 1 is
# normal.
run_scan() {
  local tf_dir="$1" last_file="$2" hist_file="$3" label="$4"
  local timestamp raw_json tfsec_exit record critical_count high_count gate hist_tmp

  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  raw_json="$(mktemp)"

  # NOTE: deliberately NOT --force-all-dirs. That flag makes tfsec treat
  # every subdirectory as its own scan root — and since terraform/azure/
  # lives PHYSICALLY INSIDE terraform/, scanning terraform/ with that flag
  # recursively swept up Azure's findings (including its own fixture) into
  # the AWS gate, contaminating the very decoupling this script's PURPOSE
  # comment promises. Confirmed directly (2026-08-13): normal module-graph
  # resolution (no flag) still finds every AWS module's own findings
  # correctly (module.network, module.storage, etc., via their `source =
  # "./modules/..."` references) — the flag was never needed for that, and
  # this bug predates today's change (present since terraform/azure/ was
  # first created in Step 3, just never exercised until this scan.sh work
  # tested the two gates side by side).
  set +e
  tfsec "$tf_dir" -f json --no-color >"$raw_json" 2>"${raw_json}.err"
  tfsec_exit=$?
  set -e

  if [[ $tfsec_exit -eq 2 || $tfsec_exit -eq 3 ]]; then
    echo "FATAL: tfsec failed to run against $tf_dir (exit $tfsec_exit)" >&2
    cat "${raw_json}.err" >&2 || true
    rm -f "$raw_json" "${raw_json}.err"
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
  rm -f "$raw_json" "${raw_json}.err"

  # Note: tfsec itself counts *only non-ignored* results when it exits 1.
  # The "counts" above already exclude ignored findings.
  critical_count="$(echo "$record" | jq '.counts.critical')"
  high_count="$(echo "$record" | jq '.counts.high')"

  if [[ "$critical_count" -gt 0 || "$high_count" -gt 0 ]]; then
    gate="FAIL"
  else
    gate="PASS"
  fi
  echo "$record" | jq --arg gate "$gate" '. + {gate: $gate}' >"$last_file"

  # ---- Append to history (atomic, JSON-line style) -------------------------
  # SEC_INTENT: if the history file is missing/corrupt, recover as empty
  # array rather than failing the gate.
  # NOTE: history intentionally stores $record WITHOUT the gate field —
  # preserves this script's pre-existing behavior exactly (only *-last.json
  # ever had a gate field), not something this change alters.
  hist_tmp="$(mktemp)"
  if [[ -s "$hist_file" ]] && jq -e 'type == "array"' "$hist_file" >/dev/null 2>&1; then
    jq --argjson r "$record" '. + [$r]' "$hist_file" >"$hist_tmp"
  else
    echo "[$record]" | jq '.' >"$hist_tmp"
  fi
  mv "$hist_tmp" "$hist_file"

  {
    echo "---- tfsec scan: $label ($timestamp) ----"
    echo "  version:  $required_tfsec"
    echo "  results:  critical=$critical_count high=$high_count \
              medium=$(echo "$record" | jq '.counts.medium') \
              low=$(echo "$record" | jq '.counts.low')"
    echo "  gate:     $gate"
    if [[ "$gate" == "FAIL" ]]; then
      echo ""
      echo "  FAILING findings ($label):"
      echo "$record" | jq -r '.findings[] | select(.severity=="CRITICAL" or .severity=="HIGH") | "    [\(.severity)] \(.rule_id) on \(.resource) (line \(.line))"'
      echo ""
    fi
  } >&2

  echo "$gate"
}

# ---- AWS scan (gates this script's exit code) ------------------------------
aws_gate="$(run_scan "$ROOT_DIR/terraform" "$DASH_DATA/tfsec-last.json" "$DASH_DATA/tfsec-history.json" "AWS (terraform/)")"

# ---- Azure scan (independent — does NOT affect this script's exit code) ---
azure_gate="$(run_scan "$ROOT_DIR/terraform/azure" "$DASH_DATA/tfsec-azure-last.json" "$DASH_DATA/tfsec-azure-history.json" "Azure (terraform/azure/)")"

echo "  dashboard (AWS):   $DASH_DATA/tfsec-last.json" >&2
echo "  dashboard (Azure): $DASH_DATA/tfsec-azure-last.json" >&2

if [[ "$azure_gate" == "FAIL" ]]; then
  echo "" >&2
  echo "  NOTE: Azure gate is FAIL — does not block this script's exit code (see PURPOSE)." >&2
  echo "    If this is the AVD-AZU-0013 fixture, run:" >&2
  echo "    ./scripts/toggle-fixture-azure.sh off" >&2
fi

if [[ "$aws_gate" == "FAIL" ]]; then
  echo "" >&2
  echo "  AWS deploy is BLOCKED. Fix the findings, or run:" >&2
  echo "    ./scripts/toggle-fixture.sh off   # if the failing resource is the deliberate fixture" >&2
  echo "  Then re-run this script." >&2
  exit 1
fi

exit 0
