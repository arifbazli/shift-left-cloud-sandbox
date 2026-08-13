#!/usr/bin/env bash
# =============================================================================
# scripts/grow-stack.sh
# =============================================================================
# Purpose
#   Incrementally build out the floci stack by applying exactly ONE new
#   terraform resource per invocation, using `terraform apply -target=<addr>`
#   against the ordered list in growth-queue.yaml. Every address in that
#   queue already exists in terraform/modules/**/*.tf — this script never
#   edits *.tf, never invents a resource, never destroys anything.
#
# Action space (the allowlist)
#   ALLOW:  terraform state list   (read-only)
#           terraform apply -target=<single address from growth-queue.yaml>
#   DENY:   terraform destroy
#           any edit to *.tf
#           any target not listed in growth-queue.yaml
#           applying more than one target per invocation
#
# Preconditions (fail loud, do nothing)
#   1. dashboard/public/data/tfsec-last.json must show gate == PASS — same
#      principle scripts/agent-loop.sh applies to drift reconciliation,
#      independently re-checked here (this script does not call agent-loop.sh).
#   2. floci-core must be reachable at FLOCI_ENDPOINT.
#   3. growth-queue.yaml must exist and contain at least one address.
#
# Output
#   - dashboard/public/data/growth-last.json    (latest attempt, success or fail)
#   - dashboard/public/data/growth-history.json (append-only log, same pattern
#     as scan.sh/drift-check.sh)
#
# Queue exhaustion
#   If every address in growth-queue.yaml already appears in
#   `terraform state list`, this is NOT an error — log "growth complete" and
#   exit 0.
#
# Failure handling
#   If `terraform apply -target=$NEXT` fails, do NOT advance. Log the
#   failure with the address and exit non-zero. The SAME address is
#   retried on the next invocation — never silently skipped.
#
# SEC_INTENT:
#   Deliberately narrow, mirroring scripts/agent-loop.sh's design goal: make
#   the dangerous action (editing *.tf, destroying, or growing out of order)
#   impossible by construction, not by convention. This script is separate
#   from agent-loop.sh on purpose — it does not touch agent-loop.sh's
#   allowlist, and agent-loop.sh does not know this script exists.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TF_DIR="$ROOT_DIR/terraform"
DASH_DATA="$ROOT_DIR/dashboard/public/data"
QUEUE_FILE="$ROOT_DIR/growth-queue.yaml"
TFSEC_LAST="$DASH_DATA/tfsec-last.json"
LAST_FILE="$DASH_DATA/growth-last.json"
HIST_FILE="$DASH_DATA/growth-history.json"

mkdir -p "$DASH_DATA"

# ---- Precondition 1: tfsec gate must be PASS -------------------------------
# SEC_INTENT: don't grow the stack while a HIGH/CRITICAL finding is open —
# same reasoning as agent-loop.sh's drift freeze, independently enforced.
if [[ ! -s "$TFSEC_LAST" ]]; then
  echo "FATAL: $TFSEC_LAST is missing — cannot confirm gate is PASS. Refusing to grow." >&2
  exit 2
fi
gate="$(jq -r '.gate // "UNKNOWN"' "$TFSEC_LAST")"
if [[ "$gate" != "PASS" ]]; then
  echo "FATAL: tfsec gate is $gate (expected PASS). Refusing to grow the stack." >&2
  exit 2
fi

# ---- Precondition 2: floci-core reachable ----------------------------------
FLOCI_ENDPOINT="${FLOCI_ENDPOINT:-http://localhost:4566}"
if ! curl -sf -m 3 -o /dev/null "$FLOCI_ENDPOINT/health" 2>/dev/null \
   && ! curl -sf -m 3 -o /dev/null "$FLOCI_ENDPOINT/" 2>/dev/null; then
  echo "FATAL: floci-core is not reachable at $FLOCI_ENDPOINT" >&2
  exit 2
fi

# ---- Precondition 3: growth-queue.yaml exists and is non-empty ------------
if [[ ! -s "$QUEUE_FILE" ]]; then
  echo "FATAL: $QUEUE_FILE not found or empty." >&2
  exit 2
fi

mapfile -t QUEUE < <(grep -E '^[[:space:]]*-[[:space:]]+module\.' "$QUEUE_FILE" \
  | sed -E 's/^[[:space:]]*-[[:space:]]+([^[:space:]#]+).*/\1/')

if [[ "${#QUEUE[@]}" -eq 0 ]]; then
  echo "FATAL: no addresses parsed from $QUEUE_FILE." >&2
  exit 2
fi

# ---- floci-only env (mirrors scripts/deploy.sh's exports) ------------------
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
# (only TF_VAR_localstack_endpoint below is read by providers.tf's
#  endpoints{} block — see deploy.sh for the full explanation)
export TF_VAR_localstack_enabled=true
export TF_VAR_localstack_endpoint="$FLOCI_ENDPOINT"

# ---- terraform init (idempotent — makes this script independently runnable)
cd "$TF_DIR"
terraform init -input=false -no-color >/tmp/grow-init.out 2>&1 \
  || { echo "FATAL: terraform init failed. See /tmp/grow-init.out." >&2; cat /tmp/grow-init.out >&2; exit 2; }

# ---- Find the next address not yet in state, count how many already are ---
existing="$(terraform state list 2>/dev/null || true)"

next=""
applied_count=0
for addr in "${QUEUE[@]}"; do
  if grep -qxF "$addr" <<<"$existing"; then
    applied_count=$((applied_count + 1))
  elif [[ -z "$next" ]]; then
    next="$addr"
  fi
done

ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ---- Queue exhausted --------------------------------------------------------
if [[ -z "$next" ]]; then
  echo "Growth complete — all ${#QUEUE[@]} queued resources already applied."
  record="$(jq -n --arg ts "$ts" --argjson total "${#QUEUE[@]}" --argjson applied "$applied_count" \
    '{timestamp: $ts, status: "complete", next_target: null, total_queued: $total, applied_count: $applied}')"
  echo "$record" | jq '.' >"$LAST_FILE"
  hist_tmp="$(mktemp)"
  if [[ -s "$HIST_FILE" ]] && jq -e 'type == "array"' "$HIST_FILE" >/dev/null 2>&1; then
    jq --argjson r "$record" '. + [$r]' "$HIST_FILE" >"$hist_tmp"
  else
    echo "[$record]" | jq '.' >"$hist_tmp"
  fi
  mv "$hist_tmp" "$HIST_FILE"
  exit 0
fi

# ---- Apply exactly one target ----------------------------------------------
echo "Next growth target: $next"
apply_output="$(mktemp)"
if terraform apply -target="$next" -auto-approve -input=false -no-color >"$apply_output" 2>&1; then
  echo "Growth step OK: $next"
  record="$(jq -n --arg ts "$ts" --arg target "$next" --argjson total "${#QUEUE[@]}" \
    --argjson applied "$((applied_count + 1))" \
    '{timestamp: $ts, status: "applied", next_target: $target, total_queued: $total, applied_count: $applied}')"
else
  echo "FAILED to apply $next — will retry the same target next run." >&2
  cat "$apply_output" >&2
  record="$(jq -n --arg ts "$ts" --arg target "$next" --argjson total "${#QUEUE[@]}" \
    --argjson applied "$applied_count" --rawfile log "$apply_output" \
    '{timestamp: $ts, status: "failed", next_target: $target, total_queued: $total, applied_count: $applied, error: $log}')"
fi

echo "$record" | jq '.' >"$LAST_FILE"
hist_tmp="$(mktemp)"
if [[ -s "$HIST_FILE" ]] && jq -e 'type == "array"' "$HIST_FILE" >/dev/null 2>&1; then
  jq --argjson r "$record" '. + [$r]' "$HIST_FILE" >"$hist_tmp"
else
  echo "[$record]" | jq '.' >"$hist_tmp"
fi
mv "$hist_tmp" "$HIST_FILE"

[[ "$(echo "$record" | jq -r '.status')" != "failed" ]]
