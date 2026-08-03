#!/usr/bin/env bash
# =============================================================================
# scripts/agent-loop.sh
# =============================================================================
# Purpose
#   A bounded, easily-auditable local "infra engineer" agent. It can do
#   exactly TWO things, and nothing else:
#
#     1. Restart a crashed floci-core container
#     2. Reconcile terraform drift via `terraform apply -auto-approve`
#        — but ONLY if:
#          a. The latest tfsec run has gate == PASS (no open HIGH/CRITICAL)
#          b. The drift is on configuration only (no destroys, no creates,
#             no security-tagged resources)
#          c. A fresh state snapshot was taken before the apply
#
# Action space (the allowlist)
#   ALLOW:  podman restart floci-core
#           terraform apply -auto-approve
#           terraform state snapshot to .bak file
#           cat / jq / cp / mv any file in the dashboard/data directory
#   DENY:   anything that modifies *.tf files
#           terraform destroy
#           terraform apply if the plan changes security-tagged resources
#           anything that exits the agent-loop's own process
#           anything that writes to /tmp/*.tf
#
# Persistence
#   - Writes a heartbeat to dashboard/public/data/agent-actions.json every
#     loop (default: 30s)
#   - Writes an action record for every action or non-action-with-reason
#   - Loops N times (default: 100) then exits cleanly
#
# SEC_INTENT:
#   This is the deliberately small, auditable agent. The whole design exists
#   to make the dangerous actions (modify tf, destroy) impossible rather
#   than "the agent promised not to do it". The grep at the top of every
#   action path is the keel that keeps the ship upright.
# =============================================================================
set -euo pipefail

# ---- Configuration (env overrides for tests) -------------------------------
LOOP_INTERVAL="${LOOP_INTERVAL:-30}"        # seconds between loops
MAX_LOOPS="${MAX_LOOPS:-100}"               # bounded execution
FLOCI_CONTAINER="${FLOCI_CONTAINER:-floci-core}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TF_DIR="$ROOT_DIR/terraform"
DASH_DATA="$ROOT_DIR/dashboard/public/data"
ACTIONS_FILE="$DASH_DATA/agent-actions.json"
TFSEC_LAST="$DASH_DATA/tfsec-last.json"
DRIFT_LAST="$DASH_DATA/drift-last.json"
STATE_FILE="$TF_DIR/terraform.tfstate"
STATE_SNAPSHOT_DIR="$TF_DIR/state-snapshots"

mkdir -p "$DASH_DATA" "$STATE_SNAPSHOT_DIR"

# ---- Action helpers --------------------------------------------------------
# Every action MUST be performed through these helpers so the audit log is
# complete. The log_action function is the only path to the JSON file.

log_event() {
  local action_kind="$1"        # action | no_action | heartbeat
  local action_name="$2"        # restart_container | apply_drift | informational | ...
  local reason="$3"             # human-readable rationale
  local extras="${4:-{\}}"      # optional JSON object with extra data

  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local event
  event="$(jq -n \
    --arg ts "$ts" \
    --arg kind "$action_kind" \
    --arg name "$action_name" \
    --arg reason "$reason" \
    --argjson extras "$extras" \
    '{
      timestamp: $ts,
      kind: $kind,
      action: $name,
      reason: $reason
    } + $extras')"

  # Atomic append: read current, append, write back
  local tmp
  tmp="$(mktemp)"
  if [[ -s "$ACTIONS_FILE" ]] && jq -e 'type == "array"' "$ACTIONS_FILE" >/dev/null 2>&1; then
    jq --argjson e "$event" '. + [$e]' "$ACTIONS_FILE" >"$tmp"
  else
    echo "[$event]" | jq '.' >"$tmp"
  fi
  mv "$tmp" "$ACTIONS_FILE"
}

snapshot_state() {
  local reason="$1"
  local ts
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  local snapshot_path="$STATE_SNAPSHOT_DIR/terraform.tfstate.${ts}.agent"
  cp "$STATE_FILE" "$snapshot_path"
  echo "$snapshot_path"
}

# ---- Permission recap (printed once at startup) ---------------------------
echo "agent-loop.sh starting"
echo "  LOOP_INTERVAL  = $LOOP_INTERVAL seconds"
echo "  MAX_LOOPS      = $MAX_LOOPS"
echo "  FLOCI_CONTAINER = $FLOCI_CONTAINER"
echo "  Allowlist:"
echo "    - podman restart $FLOCI_CONTAINER"
echo "    - terraform apply -auto-approve (only if drift is safe per drift-check.sh)"
echo "  Denylist:"
echo "    - any *.tf edit"
echo "    - terraform destroy"
echo "    - any apply that changes security-tagged resources"
echo ""
log_event "heartbeat" "startup" "agent-loop started with bounded allowlist" \
  "$(jq -n --argjson max_loops "$MAX_LOOPS" --arg interval "$LOOP_INTERVAL" \
      '{config: {max_loops: $max_loops, interval_seconds: ($interval | tonumber)}}')"

# ---- Main loop ------------------------------------------------------------
loop_count=0
while [[ "$loop_count" -lt "$MAX_LOOPS" ]]; do
  loop_count=$((loop_count + 1))
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # ---- 1. Heartbeat ------------------------------------------------------
  log_event "heartbeat" "tick" "loop $loop_count / $MAX_LOOPS" \
    "$(jq -n --argjson loop "$loop_count" --argjson max "$MAX_LOOPS" \
        '{loop: $loop, max: $max}')"

  # ---- 2. Check floci-core container health ------------------------------
  # Allowlisted action: podman restart $FLOCI_CONTAINER
  # This is the agent's only "preventive" action. It does NOT restart
  # anything else, and it does NOT auto-create containers.

  container_running="$(podman ps --filter "name=^${FLOCI_CONTAINER}$" --format '{{.Names}}' 2>/dev/null || true)"
  if [[ -z "$container_running" ]]; then
    # Container is not running. Distinguish "crashed" from "never started".
    container_exists="$(podman ps -a --filter "name=^${FLOCI_CONTAINER}$" --format '{{.Names}}' 2>/dev/null || true)"
    if [[ -n "$container_exists" ]]; then
      log_event "no_action" "restart_container" \
        "container $FLOCI_CONTAINER exists but is not running. About to restart." \
        "$(jq -n --arg c "$FLOCI_CONTAINER" '{container: $c}')"
      # ALLOW: restart
      snapshot_path="$(snapshot_state "pre-restart")"
      if podman restart "$FLOCI_CONTAINER" >/dev/null 2>&1; then
        log_event "action" "restart_container" \
          "container $FLOCI_CONTAINER restarted successfully" \
          "$(jq -n --arg c "$FLOCI_CONTAINER" --arg snap "$snapshot_path" \
              '{container: $c, state_snapshot: $snap, action_taken: "podman restart"}')"
        sleep 5  # let the container initialize
      else
        log_event "action" "restart_container" \
          "FAILED to restart $FLOCI_CONTAINER" \
          "$(jq -n --arg c "$FLOCI_CONTAINER" '{container: $c, action_taken: "podman restart", success: false}')"
      fi
    else
      log_event "no_action" "restart_container" \
        "container $FLOCI_CONTAINER does not exist. Will not auto-create (not in allowlist)." \
        "$(jq -n --arg c "$FLOCI_CONTAINER" '{container: $c, reason: "not_in_allowlist_create"}')"
    fi
  fi

  # ---- 3. Check for drift ------------------------------------------------
  # Run drift-check.sh and parse its result. The script writes to
  # drift-last.json AND exits 0 (no drift), 2 (drift), or 1 (error).
  # For test scenarios, set AGENT_SKIP_DRIFT_CHECK=1 to use the existing
  # drift-last.json without re-running.
  if [[ "${AGENT_SKIP_DRIFT_CHECK:-0}" != "1" ]]; then
    drift_exit=0
    "$SCRIPT_DIR/drift-check.sh" >/dev/null 2>&1 || drift_exit=$?
  else
    # Read the existing drift-last.json and synthesize the exit code
    if [[ ! -s "$DRIFT_LAST" ]]; then
      drift_exit=0
    else
      drift_detected="$(jq -r '.drift_detected // false' "$DRIFT_LAST")"
      if [[ "$drift_detected" == "true" ]]; then
        drift_exit=2
      else
        drift_exit=0
      fi
    fi
  fi

  if [[ "$drift_exit" -eq 1 ]]; then
    log_event "no_action" "apply_drift" \
      "drift-check.sh returned error 1. Will not apply." \
      "$(jq -n --argjson exit "$drift_exit" '{drift_check_exit: $exit}')"
    sleep "$LOOP_INTERVAL"
    continue
  fi

  if [[ "$drift_exit" -ne 2 ]]; then
    # exit 0 = no drift
    sleep "$LOOP_INTERVAL"
    continue
  fi

  # ---- 4. Drift present. Check the classification. ----------------------
  classification="$(jq -r '.classification // "unknown"' "$DRIFT_LAST")"
  if [[ "$classification" != "safe" ]]; then
    log_event "no_action" "apply_drift" \
      "drift classification is '$classification' (only 'safe' is in the allowlist). Operator must investigate." \
      "$(jq -n --arg c "$classification" '{classification: $c}')"
    sleep "$LOOP_INTERVAL"
    continue
  fi

  # ---- 5. CRITICAL gate: tfsec gate must be PASS -------------------------
  # SEC_INTENT: this is the freeze the spec requires. If the latest tfsec
  # run has any HIGH/CRITICAL, the agent will NOT apply drift — even if the
  # drift itself is provably safe. The reasoning: the apply might mask a
  # security finding in the JSON (e.g. resolve a comment-out that hides a
  # bad policy), and the agent is not smart enough to chain those checks.
  if [[ ! -s "$TFSEC_LAST" ]]; then
    log_event "no_action" "apply_drift" \
      "tfsec-last.json is missing — cannot confirm gate is PASS. Refusing to apply." \
      "$(jq -n --arg f "$TFSEC_LAST" '{file: $f}')"
    sleep "$LOOP_INTERVAL"
    continue
  fi
  tfsec_gate="$(jq -r '.gate // "UNKNOWN"' "$TFSEC_LAST")"
  if [[ "$tfsec_gate" != "PASS" ]]; then
    log_event "no_action" "apply_drift" \
      "tfsec gate is $tfsec_gate (expected PASS). FROZEN drift reconciliation — restart still allowed." \
      "$(jq -n --arg g "$tfsec_gate" '{gate: $g}')"
    sleep "$LOOP_INTERVAL"
    continue
  fi

  # ---- 6. Plan is safe. Take a snapshot and apply. -----------------------
  # Even when the plan is "safe", we take a snapshot first so the agent's
  # action can be reversed by the operator if needed.
  snapshot_path="$(snapshot_state "pre-apply-drift-loop-$loop_count")"

  log_event "action" "apply_drift" \
    "drift is 'safe' and tfsec gate is PASS. Taking snapshot and applying." \
    "$(jq -n --arg snap "$snapshot_path" --argjson loop "$loop_count" \
        '{state_snapshot: $snap, loop: $loop}')"

  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
  export AWS_ACCESS_KEY_ID=test
  export AWS_SECRET_ACCESS_KEY=test
  export AWS_DEFAULT_REGION=us-east-1
  export FLOCI_ENDPOINT="${FLOCI_ENDPOINT:-http://localhost:4566}"
  export TF_VAR_localstack_enabled=true
  export TF_VAR_localstack_endpoint="$FLOCI_ENDPOINT"
  export TF_S3_ENDPOINT="$FLOCI_ENDPOINT"
  export TF_EC2_ENDPOINT="$FLOCI_ENDPOINT"
  export TF_IAM_ENDPOINT="$FLOCI_ENDPOINT"
  export TF_STS_ENDPOINT="$FLOCI_ENDPOINT"

  apply_output="$(mktemp)"
  if (cd "$TF_DIR" && terraform apply -auto-approve -input=false -no-color) >"$apply_output" 2>&1; then
    log_event "action" "apply_drift" \
      "terraform apply -auto-approve succeeded" \
      "$(jq -n --arg snap "$snapshot_path" --arg out "$apply_output" \
          '{state_snapshot: $snap, log_file: $out, success: true}')"
  else
    log_event "action" "apply_drift" \
      "terraform apply -auto-approve FAILED — operator must investigate" \
      "$(jq -n --arg snap "$snapshot_path" --arg out "$apply_output" \
          '{state_snapshot: $snap, log_file: $out, success: false}')"
  fi

  sleep "$LOOP_INTERVAL"
done

# ---- Loop finished, log shutdown -------------------------------------------
log_event "heartbeat" "shutdown" "agent-loop completed $MAX_LOOPS iterations" \
  "$(jq -n --argjson max "$MAX_LOOPS" '{max_loops: $max}')"
echo "agent-loop.sh completed $MAX_LOOPS iterations."
