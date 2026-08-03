#!/usr/bin/env bash
# =============================================================================
# scripts/drift-check.sh
# =============================================================================
# Purpose
#   Detect drift between the recorded terraform state and what exists in
#   floci-core. Uses `terraform plan -detailed-exitcode`:
#     exit 0 = no changes
#     exit 1 = error
#     exit 2 = drift detected (the documented behavior)
#
# Output
#   - Writes dashboard/public/data/drift-history.json
#   - Writes dashboard/public/data/drift-last.json
#   - Exits 0 if NO drift, 1 if error, 2 if drift (so the agent-loop can
#     use this exit code as the trigger)
#
# SEC_INTENT: drift detection is the agent's ONLY legitimate trigger for
# `terraform apply`. We must NOT conflate "drift" with "security finding
# requires fix" — the agent-loop has separate gates for both.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TF_DIR="$ROOT_DIR/terraform"
DASH_DATA="$ROOT_DIR/dashboard/public/data"
LAST_FILE="$DASH_DATA/drift-last.json"
HIST_FILE="$DASH_DATA/drift-history.json"

mkdir -p "$DASH_DATA"

# ---- floci reachable? ----------------------------------------------------
FLOCI_ENDPOINT="${FLOCI_ENDPOINT:-http://localhost:4566}"
export FLOCI_ENDPOINT
AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION
export TF_VAR_localstack_enabled=true
export TF_VAR_localstack_endpoint="$FLOCI_ENDPOINT"
export TF_S3_ENDPOINT="$FLOCI_ENDPOINT"
export TF_EC2_ENDPOINT="$FLOCI_ENDPOINT"
export TF_IAM_ENDPOINT="$FLOCI_ENDPOINT"
export TF_STS_ENDPOINT="$FLOCI_ENDPOINT"

if ! curl -sf -m 3 -o /dev/null "$FLOCI_ENDPOINT/health" 2>/dev/null \
   && ! curl -sf -m 3 -o /dev/null "$FLOCI_ENDPOINT/" 2>/dev/null; then
  echo "FATAL: floci-core is not reachable at $FLOCI_ENDPOINT" >&2
  exit 2
fi

# ---- terraform plan -detailed-exitcode -----------------------------------
# We capture the full plan output as a file (for the dashboard to render
# later) and the JSON form for machine reading.
cd "$TF_DIR"
ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
plan_text="$(mktemp)"
plan_json="$(mktemp)"
trap 'rm -f "$plan_text" "$plan_json"' EXIT

# -no-color: easier to scan
# -input=false: don't prompt
# -detailed-exitcode: 0 = no change, 1 = error, 2 = drift
# -out: write the plan file so we can show it (passes through to the JSON form)
set +e
terraform plan -no-color -input=false -detailed-exitcode -out="$TF_DIR/.drift.tfplan" >"$plan_text" 2>&1
plan_exit=$?
set -e

# Convert to JSON for the dashboard
if [[ -f "$TF_DIR/.drift.tfplan" ]]; then
  terraform show -json "$TF_DIR/.drift.tfplan" >"$plan_json" 2>/dev/null || echo '{}' >"$plan_json"
else
  echo '{}' >"$plan_json"
fi

# ---- Decode the result ----------------------------------------------------
drift=false
result="no_drift"
case "$plan_exit" in
  0) result="no_drift" ;;
  1) result="error" ;;
  2) result="drift"   ; drift=true ;;
  *) result="unexpected_exit_$plan_exit" ;;
esac

# ---- Classify the drift (security-tagged vs not) ---------------------------
# For the agent-loop's allowlist, we need to know whether the drift is
# ONLY on resources that are safe to auto-apply (e.g. tags, description)
# OR whether it touches security-tagged resources (IAM, S3 public access,
# SG ingress) OR is destructive (delete).
#
# SEC_INTENT: the agent-loop's allowlist is explicit about no destroys.
# We classify drift here so the agent doesn't have to re-parse plan JSON.
# Classification:
#   safe:           no delete, no create, no replace, only 'update' on
#                   already-known resources AND those resources are not in
#                   the security list (IAM, S3 public access, SG ingress)
#   destructive:    any delete or create or replace-with-new-id
#   security_only:  drift is only on security-tagged resources
#   mixed:          more than one of the above
plan_summary="$(jq '
  if .resource_changes then
    [.resource_changes[] | {
      address: .address,
      type: .type,
      actions: .change.actions,
      has_security_path: (
        (.address | test("aws_iam_")) or
        (.address | test("aws_s3_bucket_public_access_block")) or
        (.address | test("aws_security_group_rule")) or
        (.address | test("aws_kms_"))
      )
    }]
  else
    []
  end
' "$plan_json" 2>/dev/null || echo '[]')"

# Reduce the summary to a classification
classification="$(echo "$plan_summary" | jq -r '
  if length == 0 then "no_drift"
  else
    (map(.actions | tostring | test("delete")) | any | tostring) as $has_delete |
    (map(.actions | tostring | test("create")) | any | tostring) as $has_create |
    (map(.has_security_path) | any | tostring) as $has_security |
    if ($has_delete == "true" or $has_create == "true") then "destructive"
    elif $has_security == "true" then "security_only"
    else "safe"
    end
  end
')"

# ---- Write the dashboard JSON ---------------------------------------------
report="$(jq -n \
  --arg ts "$ts" \
  --arg result "$result" \
  --arg classification "$classification" \
  --argjson drift "$drift" \
  --argjson summary "$plan_summary" \
  '{
    timestamp: $ts,
    result: $result,
    drift_detected: $drift,
    classification: $classification,
    changes: $summary,
    plan_text_path: "data/drift-history.json"
  }')"

echo "$report" | jq '.' >"$LAST_FILE"

# Append to history
hist_tmp="$(mktemp)"
if [[ -s "$HIST_FILE" ]] && jq -e 'type == "array"' "$HIST_FILE" >/dev/null 2>&1; then
  jq --argjson r "$report" '. + [$r]' "$HIST_FILE" >"$hist_tmp"
else
  echo "[$report]" | jq '.' >"$hist_tmp"
fi
mv "$hist_tmp" "$HIST_FILE"

# ---- Human summary --------------------------------------------------------
echo "---- drift-check ($ts) ----"
echo "  result:        $result"
echo "  classification: $classification"
echo "  changes:       $(echo "$plan_summary" | jq 'length') resource(s)"
if [[ "$drift" == true ]]; then
  echo "$plan_summary" | jq -r '.[] | "    - \(.address) [actions=\(.actions | tostring)] [security_path=\(.has_security_path)]"'
  echo ""
  if [[ "$classification" == "destructive" ]]; then
    echo "EXIT 2 = drift detected, but DESTRUCTIVE (delete/create/replace)."
    echo "  agent-loop.sh will NOT auto-reconcile this. Run scripts/deploy.sh manually."
  elif [[ "$classification" == "security_only" ]]; then
    echo "EXIT 2 = drift on security-tagged resources only."
    echo "  agent-loop.sh will NOT auto-reconcile this. Run scripts/deploy.sh manually."
  fi
  exit 2
fi
if [[ "$result" == "error" ]]; then
  echo "Plan error follows:"
  tail -20 "$plan_text" >&2
  exit 1
fi
echo "No drift. Plan matches floci state exactly."
exit 0
