#!/usr/bin/env bash
# =============================================================================
# scripts/drift-check-azure.sh
# =============================================================================
# Purpose
#   Azure sibling of scripts/drift-check.sh — detect drift between
#   terraform/azure's recorded state and what actually exists in floci-az,
#   via `terraform plan -detailed-exitcode` (0 = no change, 1 = error,
#   2 = drift).
#
# WHY THIS ISN'T A STRAIGHT PORT OF drift-check.sh
#   drift-check.sh assumes the whole AWS stack was already fully applied
#   by deploy.sh in one shot — any plan diff after that IS drift. Azure has
#   no deploy-azure.sh: the stack grows incrementally, one resource per
#   scheduled run (see growth-queue-azure.yaml / grow-stack-azure.sh). A
#   plain full `terraform plan` against terraform/azure will therefore
#   almost always show pending "+ create" actions for whatever hasn't been
#   grown yet — that is NOT drift, it's just "not there yet". This script
#   captures `terraform state list` before planning and classifies a
#   "create" action on an address that wasn't already in state as
#   `pending_growth`, excluded from both the drift classification and the
#   exit code. Any other action (update/delete/replace) on an address that
#   WAS already in state is real drift, classified exactly like
#   drift-check.sh does (safe / destructive / security_only).
#
# EMPIRICAL CHECK BEFORE BUILDING THIS (2026-08-14) — see CONTEXT.md's
# Research log for the full writeup. Per-item full parity from
# verify-azure.sh does NOT carry over unchanged here: `terraform plan` is a
# different code path than a raw curl, and it was tested directly rather
# than assumed to fail the same way.
#   - A full `terraform plan` against terraform/azure — INCLUDING the 3
#     confirmed DNS-hang resources and the AKS/Service-Plan confirmed
#     failures, all still in the config — completed in ~13 seconds, no
#     hang. `terraform plan` does not need to contact a resource's own API
#     to propose creating something not yet in state, so the DNS-hang
#     resources' unreachable hostnames never come into play during PLAN
#     the way they do during APPLY. The PLAN_TIMEOUT_SECONDS wrap below is
#     kept anyway as a safety net (same "don't trust an external call"
#     discipline as grow-stack-azure.sh) — it is NOT a response to an
#     observed hang the way grow-stack-azure.sh's 240s was.
#   - That same test surfaced a real, useful finding: `azurerm_storage_
#     account.main` — already applied, never touched by hand — plans a
#     forced REPLACE every time, because floci-az's refresh response
#     reports `queue_encryption_key_type`/`table_encryption_key_type` as
#     "Service" when the create response had returned "Account". This is
#     the Azure-side analog of AWS's documented `aws_flow_log.main`
#     always-destructive-drift quirk (see CONTEXT.md's Known floci
#     limitation) — expected, not a bug in this script or in whatever
#     caused it.
#
# Output
#   - dashboard/public/data/drift-history-azure.json
#   - dashboard/public/data/drift-last-azure.json
#   - Exits 0 if no REAL drift (pending_growth doesn't count), 1 on plan
#     error, 2 if real drift found, 3 if the plan itself timed out (a
#     status AWS's drift-check.sh has no equivalent of, since a hang was
#     never observed there).
#
# SEC_INTENT: same as drift-check.sh — this script only plans, it never
# applies. Reconciliation (or refusal to reconcile) is agent-loop-azure.sh's
# job, using this script's classification the same way agent-loop.sh uses
# drift-check.sh's.
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TF_DIR="$ROOT_DIR/terraform/azure"
DASH_DATA="$ROOT_DIR/dashboard/public/data"
LAST_FILE="$DASH_DATA/drift-last-azure.json"
HIST_FILE="$DASH_DATA/drift-history-azure.json"
FLOCI_AZ_ENDPOINT="${FLOCI_AZ_ENDPOINT:-http://localhost:4577}"
PLAN_TIMEOUT_SECONDS="${PLAN_TIMEOUT_SECONDS:-90}"

mkdir -p "$DASH_DATA"

# ---- floci-az reachable? ----------------------------------------------------
if ! curl -sf -m 3 -o /dev/null "$FLOCI_AZ_ENDPOINT/health" 2>/dev/null; then
  echo "FATAL: floci-az is not reachable at $FLOCI_AZ_ENDPOINT" >&2
  exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "FATAL: jq is required but not installed." >&2
  exit 2
fi

# ---- TLS trust + provider env -----------------------------------------------
# Mandatory for the azurerm provider's metadata discovery — same mechanism
# grow-stack-azure.sh documents, never a system trust-store change.
cert_file="$(mktemp)"
trap 'rm -f "$cert_file"' EXIT
if ! curl -sf -m 5 -o "$cert_file" "$FLOCI_AZ_ENDPOINT/_floci/tls-cert" 2>/dev/null; then
  echo "FATAL: could not fetch floci-az's TLS cert from $FLOCI_AZ_ENDPOINT/_floci/tls-cert" >&2
  echo "  Was floci-az started with FLOCI_AZ_TLS_ENABLED=true? See scripts/start-floci-az.sh." >&2
  exit 2
fi
export SSL_CERT_FILE="$cert_file"
export TF_VAR_floci_az_enabled=true
export TF_VAR_floci_az_endpoint="${FLOCI_AZ_ENDPOINT#*://}"

# ---- terraform init (idempotent) -------------------------------------------
cd "$TF_DIR"
terraform init -input=false -no-color >/tmp/drift-azure-init.out 2>&1 \
  || { echo "FATAL: terraform init failed. See /tmp/drift-azure-init.out." >&2; cat /tmp/drift-azure-init.out >&2; exit 2; }

# ---- Capture what's already grown, BEFORE planning -------------------------
# This is what separates "pending growth" from real drift below.
existing_before_json="$(terraform state list 2>/dev/null | jq -R -s 'split("\n") | map(select(length > 0))')"

# ---- terraform plan -detailed-exitcode, bounded ----------------------------
ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
plan_text="$(mktemp)"
plan_json="$(mktemp)"
plan_file="$TF_DIR/.drift-azure.tfplan"
trap 'rm -f "$cert_file" "$plan_text" "$plan_json" "$plan_file"' EXIT

set +e
timeout "$PLAN_TIMEOUT_SECONDS" terraform plan -no-color -input=false -detailed-exitcode -out="$plan_file" >"$plan_text" 2>&1
plan_exit=$?
set -e

if [[ -f "$plan_file" ]]; then
  terraform show -json "$plan_file" >"$plan_json" 2>/dev/null || echo '{}' >"$plan_json"
else
  echo '{}' >"$plan_json"
fi

result="no_drift"
case "$plan_exit" in
  124) result="timed_out" ;;
  0)   result="no_drift" ;;
  1)   result="error" ;;
  2)   result="drift" ;;
  *)   result="unexpected_exit_$plan_exit" ;;
esac

# ---- Classify: pending_growth vs real drift, safe/destructive/security ----
# KNOWN_ISSUE addresses mirror verify-azure.sh's list exactly — a create
# action pending on one of these is still just "pending_growth" (it hasn't
# been grown, same as any other not-yet-applied resource); this list only
# matters if one of them ever shows a non-create action, which would be a
# genuinely new and unexpected finding worth flagging as such.
all_changes="$(jq --argjson existing "$existing_before_json" '
  if .resource_changes then
    [.resource_changes[] | select(.change.actions != ["no-op"]) | {
      address: .address,
      type: .type,
      actions: .change.actions,
      was_in_state: (.address as $a | $existing | any(. == $a)),
      known_issue: (.address | test(
        "azurerm_storage_container\\.artifacts|azurerm_storage_table\\.main|azurerm_key_vault_secret\\.app_config|azurerm_service_plan\\.functions|azurerm_linux_function_app\\.main|azurerm_kubernetes_cluster\\.main"
      )),
      has_security_path: (
        (.address | test("azurerm_network_security_rule")) or
        (.address | test("azurerm_key_vault"))
      )
    }]
  else [] end
' "$plan_json" 2>/dev/null || echo '[]')"

pending_growth="$(echo "$all_changes" | jq '[.[] | select(.was_in_state == false and .actions == ["create"])]')"
real_drift="$(echo "$all_changes" | jq '[.[] | select(.was_in_state == true or .actions != ["create"])]')"

drift_count="$(echo "$real_drift" | jq 'length')"
drift=false
[[ "$drift_count" -gt 0 ]] && drift=true

classification="$(echo "$real_drift" | jq -r '
  if length == 0 then "no_drift"
  else
    (map(.actions | any(. == "delete")) | any | tostring) as $has_delete |
    (map(.has_security_path) | any | tostring) as $has_security |
    if $has_delete == "true" then "destructive"
    elif $has_security == "true" then "security_only"
    else "safe"
    end
  end
')"

# A real-drift entry on a documented known_issue address is a genuinely new
# finding (those resources are expected to sit as pending_growth forever,
# not to show up as update/delete/replace) — surfaced distinctly so it
# doesn't get lost inside a generic "destructive"/"safe" bucket.
unexpected_known_issue_drift="$(echo "$real_drift" | jq '[.[] | select(.known_issue == true)]')"

# ---- Write the dashboard JSON ------------------------------------------------
report="$(jq -n \
  --arg ts "$ts" --arg result "$result" --arg classification "$classification" \
  --argjson drift "$drift" --argjson changes "$real_drift" \
  --argjson pending_growth "$pending_growth" \
  --argjson unexpected_known_issue_drift "$unexpected_known_issue_drift" \
  '{
    timestamp: $ts,
    result: $result,
    drift_detected: $drift,
    classification: $classification,
    changes: $changes,
    pending_growth: $pending_growth,
    unexpected_known_issue_drift: $unexpected_known_issue_drift
  }')"

echo "$report" | jq '.' >"$LAST_FILE"
hist_tmp="$(mktemp)"
if [[ -s "$HIST_FILE" ]] && jq -e 'type == "array"' "$HIST_FILE" >/dev/null 2>&1; then
  jq --argjson r "$report" '. + [$r]' "$HIST_FILE" >"$hist_tmp"
else
  echo "[$report]" | jq '.' >"$hist_tmp"
fi
mv "$hist_tmp" "$HIST_FILE"

# ---- Human summary --------------------------------------------------------
echo "---- drift-check-azure ($ts) ----"
echo "  result:          $result"
echo "  classification:  $classification"
echo "  real drift:      $drift_count resource(s)"
echo "  pending growth:  $(echo "$pending_growth" | jq 'length') resource(s) (not drift — just not grown yet)"
if [[ "$drift" == true ]]; then
  echo "$real_drift" | jq -r '.[] | "    - \(.address) [actions=\(.actions | tostring)] [security_path=\(.has_security_path)] [known_issue=\(.known_issue)]"'
fi
if [[ "$(echo "$unexpected_known_issue_drift" | jq 'length')" -gt 0 ]]; then
  echo ""
  echo "  UNEXPECTED: a documented known_issue resource shows real drift, not just pending_growth:"
  echo "$unexpected_known_issue_drift" | jq -r '.[] | "    \(.address): \(.actions | tostring)"'
fi

case "$result" in
  timed_out)
    echo "TIMED OUT after ${PLAN_TIMEOUT_SECONDS}s — see the header comment; this was not expected empirically, worth investigating." >&2
    exit 3
    ;;
  error)
    echo "Plan error follows:" >&2
    tail -20 "$plan_text" >&2
    exit 1
    ;;
esac

if [[ "$drift" == true ]]; then
  if [[ "$classification" == "destructive" ]]; then
    echo "EXIT 2 = drift detected, but DESTRUCTIVE (delete/create/replace)."
    echo "  agent-loop-azure.sh will NOT auto-reconcile this. Investigate manually."
  elif [[ "$classification" == "security_only" ]]; then
    echo "EXIT 2 = drift on security-tagged resources only."
    echo "  agent-loop-azure.sh will NOT auto-reconcile this. Investigate manually."
  fi
  exit 2
fi

echo "No real drift. ($(echo "$pending_growth" | jq 'length') resource(s) still pending growth, as expected.)"
exit 0
