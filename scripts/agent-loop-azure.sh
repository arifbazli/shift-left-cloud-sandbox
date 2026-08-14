#!/usr/bin/env bash
# =============================================================================
# scripts/agent-loop-azure.sh
# =============================================================================
# Purpose
#   Azure sibling of scripts/agent-loop.sh — a bounded, easily-auditable
#   local "infra engineer" agent that can do exactly TWO things:
#
#     1. Restart a crashed floci-az container
#     2. Reconcile terraform/azure drift via `terraform apply -auto-approve
#        -target=<addr>` — but ONLY if:
#          a. The latest Azure tfsec gate (tfsec-azure-last.json) is PASS
#          b. drift-check-azure.sh's classification is "safe"
#          c. NONE of the drifted addresses are a documented known_issue
#             resource (see below — this is the one deliberate deviation
#             from agent-loop.sh's design, confirmed with the operator
#             before building)
#          d. A fresh state snapshot was taken before the apply
#
# DELIBERATE DEVIATION 1 FROM agent-loop.sh: known_issue resources are
# EXCLUDED from auto-remediation, not merely deprioritized
#   Confirmed with the operator before writing this script (see CONTEXT.md's
#   Research log). AWS's agent-loop.sh has no such exclusion because AWS's
#   EKS/MSK/OpenSearch findings are *uncertain*, not confirmed-permanent —
#   drift on them could, in principle, resolve. Azure's 6 known_issue
#   addresses (the 3 DNS-hang resources, the Service Plan/Function App pair,
#   and AKS) are CONFIRMED PERMANENT limitations: a host-level DNS+port
#   redirect, a floci-az fallback-handler gap, and a systemd cgroup
#   delegation gap respectively — none of which this repo's scripts can fix.
#   Auto-remediating them every loop would mean retrying an apply that can
#   never succeed, forever, for no benefit. drift-check-azure.sh already
#   tags every drifted resource with `known_issue` — this script refuses to
#   apply if ANY drifted address carries that flag, rather than re-deriving
#   the address list a third time.
#
# DELIBERATE DEVIATION 2 FROM agent-loop.sh: `-target`, not a bare apply
#   agent-loop.sh's `terraform apply -auto-approve` is a full, untargeted
#   apply — safe there because AWS's deploy.sh already fully applied
#   everything, so a full apply only ever touches genuinely drifted
#   resources. Azure has no such moment: terraform/azure grows
#   incrementally (see growth-queue-azure.yaml), so a bare full apply here
#   would ALSO try to create every not-yet-grown resource — accidentally
#   doing grow-stack-azure.sh's job, with none of its timeout discipline.
#   This script applies `-target=<addr>` for exactly the addresses
#   drift-check-azure.sh reported as real (non-pending-growth) drift,
#   never a bare apply.
#
# Action space (the allowlist)
#   ALLOW:  podman restart floci-az
#           terraform apply -auto-approve -target=<addr> (one call, one or
#             more targets, all confirmed safe + non-known_issue)
#           terraform state snapshot to .bak file
#           cat / jq / cp / mv any file in the dashboard/data directory
#   DENY:   anything that modifies *.tf files
#           terraform destroy
#           terraform apply if the plan changes security-tagged resources
#           terraform apply on any known_issue address
#           a bare, untargeted terraform apply
#           anything that exits the agent-loop's own process
#           anything that writes to /tmp/*.tf
#
# Persistence
#   - Writes a heartbeat to dashboard/public/data/agent-actions-azure.json
#     every loop (default: 30s)
#   - Writes an action record for every action or non-action-with-reason
#   - Loops N times (default: 100) then exits cleanly
#
# SEC_INTENT:
#   Same design goal as agent-loop.sh: make the dangerous actions (edit tf,
#   destroy, touch a known-permanent-limitation resource) impossible by
#   construction, not "the agent promised not to". Separate script, not
#   parametrized — matches this repo's established convention. Independent
#   of agent-loop.sh; neither knows this script exists.
# =============================================================================
set -uo pipefail

LOOP_INTERVAL="${LOOP_INTERVAL:-30}"
MAX_LOOPS="${MAX_LOOPS:-100}"
FLOCI_AZ_CONTAINER="${FLOCI_AZ_CONTAINER:-floci-az}"
FLOCI_AZ_ENDPOINT="${FLOCI_AZ_ENDPOINT:-http://localhost:4577}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TF_DIR="$ROOT_DIR/terraform/azure"
DASH_DATA="$ROOT_DIR/dashboard/public/data"
ACTIONS_FILE="$DASH_DATA/agent-actions-azure.json"
TFSEC_AZURE_LAST="$DASH_DATA/tfsec-azure-last.json"
DRIFT_AZURE_LAST="$DASH_DATA/drift-last-azure.json"
STATE_FILE="$TF_DIR/terraform.tfstate"
STATE_SNAPSHOT_DIR="$TF_DIR/state-snapshots"

mkdir -p "$DASH_DATA" "$STATE_SNAPSHOT_DIR"

# ---- Action helpers ---------------------------------------------------------
log_event() {
  local action_kind="$1" action_name="$2" reason="$3" extras="${4:-{\}}"
  local ts event tmp
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  event="$(jq -n \
    --arg ts "$ts" --arg kind "$action_kind" --arg name "$action_name" --arg reason "$reason" \
    --argjson extras "$extras" \
    '{timestamp: $ts, kind: $kind, action: $name, reason: $reason} + $extras')"
  tmp="$(mktemp)"
  if [[ -s "$ACTIONS_FILE" ]] && jq -e 'type == "array"' "$ACTIONS_FILE" >/dev/null 2>&1; then
    jq --argjson e "$event" '. + [$e]' "$ACTIONS_FILE" >"$tmp"
  else
    echo "[$event]" | jq '.' >"$tmp"
  fi
  mv "$tmp" "$ACTIONS_FILE"
}

snapshot_state() {
  local ts snapshot_path
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  snapshot_path="$STATE_SNAPSHOT_DIR/terraform.tfstate.${ts}.agent-azure"
  cp "$STATE_FILE" "$snapshot_path"
  echo "$snapshot_path"
}

# fetch_tls_cert: mandatory for every terraform call against terraform/azure.
# Re-fetched every loop (not just at startup) because a container restart
# (this script's own allowlisted action) regenerates floci-az's self-signed
# cert — a cert fetched before a restart would be stale after one.
fetch_tls_cert() {
  local cert_file="$1"
  curl -sf -m 5 -o "$cert_file" "$FLOCI_AZ_ENDPOINT/_floci/tls-cert" 2>/dev/null
}

# ---- Permission recap -------------------------------------------------------
echo "agent-loop-azure.sh starting"
echo "  LOOP_INTERVAL     = $LOOP_INTERVAL seconds"
echo "  MAX_LOOPS         = $MAX_LOOPS"
echo "  FLOCI_AZ_CONTAINER = $FLOCI_AZ_CONTAINER"
echo "  Allowlist:"
echo "    - podman restart $FLOCI_AZ_CONTAINER"
echo "    - terraform apply -auto-approve -target=<addr> (safe drift, non-known_issue only)"
echo "  Denylist:"
echo "    - any *.tf edit"
echo "    - terraform destroy"
echo "    - any apply that changes security-tagged resources"
echo "    - any apply that touches a documented known_issue resource"
echo "    - a bare, untargeted terraform apply"
echo ""
log_event "heartbeat" "startup" "agent-loop-azure started with bounded allowlist" \
  "$(jq -n --argjson max_loops "$MAX_LOOPS" --arg interval "$LOOP_INTERVAL" \
      '{config: {max_loops: $max_loops, interval_seconds: ($interval | tonumber)}}')"

# ---- Main loop ---------------------------------------------------------------
loop_count=0
while [[ "$loop_count" -lt "$MAX_LOOPS" ]]; do
  loop_count=$((loop_count + 1))

  log_event "heartbeat" "tick" "loop $loop_count / $MAX_LOOPS" \
    "$(jq -n --argjson loop "$loop_count" --argjson max "$MAX_LOOPS" '{loop: $loop, max: $max}')"

  # ---- 1. Check floci-az container health --------------------------------
  container_running="$(podman ps --filter "name=^${FLOCI_AZ_CONTAINER}$" --format '{{.Names}}' 2>/dev/null || true)"
  if [[ -z "$container_running" ]]; then
    container_exists="$(podman ps -a --filter "name=^${FLOCI_AZ_CONTAINER}$" --format '{{.Names}}' 2>/dev/null || true)"
    if [[ -n "$container_exists" ]]; then
      log_event "no_action" "restart_container" \
        "container $FLOCI_AZ_CONTAINER exists but is not running. About to restart." \
        "$(jq -n --arg c "$FLOCI_AZ_CONTAINER" '{container: $c}')"
      snapshot_path="$(snapshot_state)"
      if podman restart "$FLOCI_AZ_CONTAINER" >/dev/null 2>&1; then
        log_event "action" "restart_container" \
          "container $FLOCI_AZ_CONTAINER restarted successfully" \
          "$(jq -n --arg c "$FLOCI_AZ_CONTAINER" --arg snap "$snapshot_path" \
              '{container: $c, state_snapshot: $snap, action_taken: "podman restart"}')"
        sleep 8 # let floci-az re-initialize and regenerate its TLS cert
      else
        log_event "action" "restart_container" \
          "FAILED to restart $FLOCI_AZ_CONTAINER" \
          "$(jq -n --arg c "$FLOCI_AZ_CONTAINER" '{container: $c, action_taken: "podman restart", success: false}')"
      fi
    else
      log_event "no_action" "restart_container" \
        "container $FLOCI_AZ_CONTAINER does not exist. Will not auto-create (not in allowlist)." \
        "$(jq -n --arg c "$FLOCI_AZ_CONTAINER" '{container: $c, reason: "not_in_allowlist_create"}')"
    fi
  fi

  # ---- 2. Run drift-check-azure.sh, parse its result ----------------------
  if [[ "${AGENT_SKIP_DRIFT_CHECK_AZURE:-0}" != "1" ]]; then
    drift_exit=0
    "$SCRIPT_DIR/drift-check-azure.sh" >/dev/null 2>&1 || drift_exit=$?
  else
    if [[ ! -s "$DRIFT_AZURE_LAST" ]]; then
      drift_exit=0
    else
      drift_detected="$(jq -r '.drift_detected // false' "$DRIFT_AZURE_LAST")"
      drift_exit=$([[ "$drift_detected" == "true" ]] && echo 2 || echo 0)
    fi
  fi

  if [[ "$drift_exit" -eq 1 ]]; then
    log_event "no_action" "apply_drift" \
      "drift-check-azure.sh returned error 1. Will not apply." \
      "$(jq -n --argjson exit "$drift_exit" '{drift_check_exit: $exit}')"
    sleep "$LOOP_INTERVAL"; continue
  fi
  if [[ "$drift_exit" -eq 3 ]]; then
    log_event "no_action" "apply_drift" \
      "drift-check-azure.sh's plan itself timed out (exit 3) -- not expected empirically. Will not apply." \
      "$(jq -n --argjson exit "$drift_exit" '{drift_check_exit: $exit}')"
    sleep "$LOOP_INTERVAL"; continue
  fi
  if [[ "$drift_exit" -ne 2 ]]; then
    sleep "$LOOP_INTERVAL"; continue # 0 = no real drift (pending_growth doesn't count)
  fi

  # ---- 3. Drift present. Check classification and known_issue exclusion. --
  classification="$(jq -r '.classification // "unknown"' "$DRIFT_AZURE_LAST")"
  if [[ "$classification" != "safe" ]]; then
    log_event "no_action" "apply_drift" \
      "drift classification is '$classification' (only 'safe' is in the allowlist). Operator must investigate." \
      "$(jq -n --arg c "$classification" '{classification: $c}')"
    sleep "$LOOP_INTERVAL"; continue
  fi

  # SEC_INTENT: defense in depth. A "safe" classification should never
  # contain a known_issue address (drift-check-azure.sh reports those
  # separately as unexpected_known_issue_drift), but this script does not
  # trust that invariant blindly -- it re-checks every drifted address
  # itself before ever building an apply command.
  known_issue_count="$(jq '[.changes[]? | select(.known_issue == true)] | length' "$DRIFT_AZURE_LAST")"
  if [[ "$known_issue_count" -gt 0 ]]; then
    log_event "no_action" "apply_drift" \
      "drift includes $known_issue_count documented known_issue address(es) -- excluded from auto-remediation by design (confirmed permanent limitations, not uncertain like AWS's EKS/MSK). Operator must investigate." \
      "$(jq '{known_issue_addresses: [.changes[]? | select(.known_issue == true) | .address]}' "$DRIFT_AZURE_LAST")"
    sleep "$LOOP_INTERVAL"; continue
  fi

  targets="$(jq -r '[.changes[]?.address] | .[]' "$DRIFT_AZURE_LAST")"
  if [[ -z "$targets" ]]; then
    sleep "$LOOP_INTERVAL"; continue
  fi

  # ---- 4. CRITICAL gate: Azure tfsec gate must be PASS ---------------------
  if [[ ! -s "$TFSEC_AZURE_LAST" ]]; then
    log_event "no_action" "apply_drift" \
      "tfsec-azure-last.json is missing -- cannot confirm gate is PASS. Refusing to apply." \
      "$(jq -n --arg f "$TFSEC_AZURE_LAST" '{file: $f}')"
    sleep "$LOOP_INTERVAL"; continue
  fi
  tfsec_gate="$(jq -r '.gate // "UNKNOWN"' "$TFSEC_AZURE_LAST")"
  if [[ "$tfsec_gate" != "PASS" ]]; then
    log_event "no_action" "apply_drift" \
      "Azure tfsec gate is $tfsec_gate (expected PASS). FROZEN drift reconciliation -- restart still allowed." \
      "$(jq -n --arg g "$tfsec_gate" '{gate: $g}')"
    sleep "$LOOP_INTERVAL"; continue
  fi

  # ---- 5. Plan is safe, non-known_issue. Snapshot, fetch cert, apply. ------
  cert_file="$(mktemp)"
  if ! fetch_tls_cert "$cert_file"; then
    log_event "no_action" "apply_drift" \
      "could not fetch floci-az's TLS cert -- refusing to apply." \
      "$(jq -n --arg ep "$FLOCI_AZ_ENDPOINT" '{endpoint: $ep}')"
    rm -f "$cert_file"
    sleep "$LOOP_INTERVAL"; continue
  fi

  snapshot_path="$(snapshot_state)"
  target_args=()
  while IFS= read -r addr; do target_args+=("-target=$addr"); done <<<"$targets"

  log_event "action" "apply_drift" \
    "drift is 'safe', no known_issue addresses, tfsec gate is PASS. Taking snapshot and applying $(echo "$targets" | wc -l) target(s)." \
    "$(jq -n --arg snap "$snapshot_path" --argjson loop "$loop_count" --arg t "$targets" \
        '{state_snapshot: $snap, loop: $loop, targets: ($t | split("\n") | map(select(length>0)))}')"

  export SSL_CERT_FILE="$cert_file"
  export TF_VAR_floci_az_enabled=true
  export TF_VAR_floci_az_endpoint="${FLOCI_AZ_ENDPOINT#*://}"

  apply_output="$(mktemp)"
  if (cd "$TF_DIR" && terraform apply -auto-approve -input=false -no-color "${target_args[@]}") >"$apply_output" 2>&1; then
    log_event "action" "apply_drift" \
      "terraform apply -auto-approve (targeted) succeeded" \
      "$(jq -n --arg snap "$snapshot_path" --arg out "$apply_output" '{state_snapshot: $snap, log_file: $out, success: true}')"
  else
    log_event "action" "apply_drift" \
      "terraform apply -auto-approve (targeted) FAILED -- operator must investigate" \
      "$(jq -n --arg snap "$snapshot_path" --arg out "$apply_output" '{state_snapshot: $snap, log_file: $out, success: false}')"
  fi
  rm -f "$cert_file"

  sleep "$LOOP_INTERVAL"
done

log_event "heartbeat" "shutdown" "agent-loop-azure completed $MAX_LOOPS iterations" \
  "$(jq -n --argjson max "$MAX_LOOPS" '{max_loops: $max}')"
echo "agent-loop-azure.sh completed $MAX_LOOPS iterations."
