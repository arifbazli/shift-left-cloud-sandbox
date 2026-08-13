#!/usr/bin/env bash
# =============================================================================
# scripts/grow-stack-azure.sh
# =============================================================================
# Purpose
#   Azure sibling of scripts/grow-stack.sh (AWS) — incrementally builds out
#   the floci-az stack by applying exactly ONE new terraform resource per
#   invocation, using `terraform apply -target=<addr>` against the ordered
#   list in growth-queue-azure.yaml. Every address in that queue already
#   exists in terraform/modules/azure-*/**/*.tf — this script never edits
#   *.tf, never invents a resource, never destroys anything. Separate
#   script, not parametrized, matching this repo's established convention.
#
# Action space (the allowlist)
#   ALLOW:  terraform state list   (read-only, against terraform/azure)
#           terraform apply -target=<single address from growth-queue-azure.yaml>
#   DENY:   terraform destroy
#           any edit to *.tf
#           any target not listed in growth-queue-azure.yaml
#           applying more than one target per invocation
#
# Preconditions (fail loud, do nothing)
#   1. tfsec gate against terraform/azure must show PASS. UNLIKE grow-
#      stack.sh (AWS), which reads an EXISTING dashboard/public/data/
#      tfsec-last.json written by scan.sh, there is no Azure-scoped gate
#      file yet — scripts/scan.sh does not scan terraform/azure/ (out of
#      scope, see CONTEXT.md). This script runs tfsec against terraform/
#      azure directly, itself, as its own self-contained precondition,
#      rather than trusting a file nothing currently produces. Adaptation,
#      not a literal mirror — flagged for review.
#   2. floci-az must be reachable at FLOCI_AZ_ENDPOINT.
#   3. growth-queue-azure.yaml must exist and contain at least one address.
#
# Output
#   - dashboard/public/data/growth-last-azure.json    (latest attempt)
#   - dashboard/public/data/growth-history-azure.json (append-only log)
#
# Queue exhaustion
#   If every address in growth-queue-azure.yaml already appears in
#   `terraform state list`, this is NOT an error — log "growth complete"
#   and exit 0.
#
# Failure handling
#   If `terraform apply -target=$NEXT` fails OR does not complete within
#   APPLY_TIMEOUT_SECONDS, do NOT advance. Log the failure/timeout with the
#   address and exit non-zero. The SAME address is retried on the next
#   invocation — never silently skipped.
#
#   DELIBERATE DEVIATION FROM grow-stack.sh: an explicit wall-clock timeout
#   wraps the apply call here, default 240s. AWS's growth loop assumes a
#   stuck target eventually returns (fails fast, or is slow but bounded by
#   the provider's own internal timeout). Confirmed 2026-08-13: several
#   Azure targets (storage container/table, Key Vault secret, Service
#   Plan) hang with NO error and NO observed natural timeout within 10+
#   minutes of direct testing — a dead client-side stall with ZERO
#   incremental server-side activity at any point, not just slowness.
#   Those targets would time out identically at 30s or at 300s — there is
#   NO evidence a longer wait helps them. The 240s floor exists ONLY
#   because of two CONFIRMED-WORKING, merely-chatty resources on this same
#   queue: azurerm_storage_account.main and azurerm_storage_account.
#   functions, both measured at 2m54s (174s) in a real apply — many
#   sequential provider-side calls to populate ~80 computed attributes,
#   not a bug. 240s gives that case ~38% margin without carrying padding
#   that only benefits targets with no evidence they'd ever finish. A
#   smarter per-resource timeout (a table keyed by address) would let the
#   stuck items fail fast without risking the slow-but-working ones —
#   not built, out of scope tonight.
#
# SEC_INTENT:
#   Deliberately narrow, mirroring scripts/grow-stack.sh's (and by
#   extension scripts/agent-loop.sh's) design goal: make the dangerous
#   action (editing *.tf, destroying, or growing out of order) impossible
#   by construction, not by convention. Separate from grow-stack.sh and
#   agent-loop.sh on purpose — neither knows this script exists.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TF_DIR="$ROOT_DIR/terraform/azure"
DASH_DATA="$ROOT_DIR/dashboard/public/data"
QUEUE_FILE="$ROOT_DIR/growth-queue-azure.yaml"
LAST_FILE="$DASH_DATA/growth-last-azure.json"
HIST_FILE="$DASH_DATA/growth-history-azure.json"
APPLY_TIMEOUT_SECONDS="${APPLY_TIMEOUT_SECONDS:-240}"

mkdir -p "$DASH_DATA"

# ---- Precondition 1: tfsec gate must be PASS, checked directly -------------
# SEC_INTENT: same reasoning as grow-stack.sh — don't grow while a HIGH/
# CRITICAL finding is open. Self-contained (see header) since no external
# gate file for terraform/azure exists yet.
if ! command -v tfsec >/dev/null 2>&1; then
  echo "FATAL: tfsec is not installed — cannot confirm gate is PASS. Refusing to grow." >&2
  exit 2
fi
tfsec_json="$(mktemp)"
set +e
tfsec "$TF_DIR" -f json --no-color --force-all-dirs >"$tfsec_json" 2>/dev/null
set -e
critical_count="$(jq '[.results[]? | select(.severity=="CRITICAL")] | length' "$tfsec_json" 2>/dev/null || echo 1)"
high_count="$(jq '[.results[]? | select(.severity=="HIGH")] | length' "$tfsec_json" 2>/dev/null || echo 1)"
rm -f "$tfsec_json"
if [[ "$critical_count" -gt 0 || "$high_count" -gt 0 ]]; then
  echo "FATAL: tfsec gate against terraform/azure is not PASS (critical=$critical_count high=$high_count). Refusing to grow." >&2
  echo "  If this is the AVD-AZU-0013 fixture, run: ./scripts/toggle-fixture-azure.sh off" >&2
  exit 2
fi

# ---- Precondition 2: floci-az reachable ------------------------------------
FLOCI_AZ_ENDPOINT="${FLOCI_AZ_ENDPOINT:-http://localhost:4577}"
if ! curl -sf -m 3 -o /dev/null "$FLOCI_AZ_ENDPOINT/health" 2>/dev/null; then
  echo "FATAL: floci-az is not reachable at $FLOCI_AZ_ENDPOINT" >&2
  exit 2
fi

# ---- Precondition 3: growth-queue-azure.yaml exists and is non-empty ------
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

# ---- floci-az-only env ------------------------------------------------------
# TLS is mandatory for the azurerm provider's metadata discovery (see
# terraform/azure/providers.tf) — fetch floci-az's self-signed cert and
# trust it for this process only, same mechanism scripts/start-floci-az.sh
# documents, never a system trust-store change.
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
terraform init -input=false -no-color >/tmp/grow-azure-init.out 2>&1 \
  || { echo "FATAL: terraform init failed. See /tmp/grow-azure-init.out." >&2; cat /tmp/grow-azure-init.out >&2; exit 2; }

# ---- Find the next address not yet in state --------------------------------
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

# ---- Apply exactly one target, bounded by APPLY_TIMEOUT_SECONDS -----------
echo "Next growth target: $next (timeout ${APPLY_TIMEOUT_SECONDS}s)"
apply_output="$(mktemp)"
apply_status="applied"
if timeout "$APPLY_TIMEOUT_SECONDS" terraform apply -target="$next" -auto-approve -input=false -no-color >"$apply_output" 2>&1; then
  echo "Growth step OK: $next"
  record="$(jq -n --arg ts "$ts" --arg target "$next" --argjson total "${#QUEUE[@]}" \
    --argjson applied "$((applied_count + 1))" \
    '{timestamp: $ts, status: "applied", next_target: $target, total_queued: $total, applied_count: $applied}')"
else
  apply_exit=$?
  if [[ "$apply_exit" -eq 124 ]]; then
    echo "TIMED OUT applying $next after ${APPLY_TIMEOUT_SECONDS}s — will retry the same target next run." >&2
    apply_status="timed_out"
  else
    echo "FAILED to apply $next — will retry the same target next run." >&2
    apply_status="failed"
  fi
  cat "$apply_output" >&2
  record="$(jq -n --arg ts "$ts" --arg target "$next" --argjson total "${#QUEUE[@]}" \
    --argjson applied "$applied_count" --arg status "$apply_status" --rawfile log "$apply_output" \
    '{timestamp: $ts, status: $status, next_target: $target, total_queued: $total, applied_count: $applied, error: $log}')"
fi

echo "$record" | jq '.' >"$LAST_FILE"
hist_tmp="$(mktemp)"
if [[ -s "$HIST_FILE" ]] && jq -e 'type == "array"' "$HIST_FILE" >/dev/null 2>&1; then
  jq --argjson r "$record" '. + [$r]' "$HIST_FILE" >"$hist_tmp"
else
  echo "[$record]" | jq '.' >"$hist_tmp"
fi
mv "$hist_tmp" "$HIST_FILE"

[[ "$(echo "$record" | jq -r '.status')" == "applied" ]]
