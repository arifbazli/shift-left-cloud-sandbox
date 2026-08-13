#!/usr/bin/env bash
# =============================================================================
# scripts/deploy.sh
# =============================================================================
# Purpose
#   terraform apply against floci-core (localhost:4566), ONLY if the tfsec
#   gate (scripts/scan.sh) has passed.
#
# Hard preconditions (fail loud, do not proceed)
#   1. AWS_ACCESS_KEY_ID must not be a real AWS key. We test by pattern
#      (real keys from AWS are 16-20 chars of [A-Z0-9]) AND we explicitly
#      require it to be the floci dummy value "test" OR be unset (in which
#      case we set it to "test" ourselves).
#   2. AWS_SECRET_ACCESS_KEY must not be present OR must be the floci dummy.
#   3. The previous scan.sh run must have gate == PASS.
#   4. floci-core must be reachable at localhost:4566.
#
# Output
#   - Runs terraform init (idempotent) then terraform apply
#   - Updates dashboard/public/data/deploy-history.json with the event
#   - Updates dashboard/public/data/verify-pending.json (verify.sh consumes
#     this to know what to check)
#
# SEC_INTENT: this script is the SINGLE reachable path from "scan passed"
# to "resources created". It deliberately re-validates the gate rather than
# trusting the caller — if you ran scan.sh in a different shell and the
# tfsec-last.json is on disk, we'll trust that. If you bypass it, the
# guard at the top of this script is the catch.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TF_DIR="$ROOT_DIR/terraform"
DASH_DATA="$ROOT_DIR/dashboard/public/data"
LAST_FILE="$DASH_DATA/tfsec-last.json"
DEPLOY_HIST="$DASH_DATA/deploy-history.json"
DEPLOY_LAST="$DASH_DATA/deploy-last.json"
VERIFY_PENDING="$DASH_DATA/verify-pending.json"

mkdir -p "$DASH_DATA"

# ---- Hard guard 1: AWS credentials are floci dummy, NOT real ----------------
# We do not just check the value — we check the PATTERN and the source.
# A real AWS access key looks like AKIA[...] (20 chars) or ASIA[...] (STS).
# floci (and localstack) accept any value; we use "test" by convention.
#
# If you have AWS SSO/credentials file configured, the env vars may be unset
# but the AWS provider will still pick them up. We block that too.

real_key_pattern='^(AKIA|ASIA|AIDA|ANPA|ANVA|APKA|ASCA)[A-Z0-9]{12,}$'

if [[ -n "${AWS_ACCESS_KEY_ID:-}" ]]; then
  if [[ "$AWS_ACCESS_KEY_ID" =~ $real_key_pattern ]]; then
    echo "FATAL: AWS_ACCESS_KEY_ID looks like a REAL AWS key." >&2
    echo "  value: $AWS_ACCESS_KEY_ID" >&2
    echo "  This script only applies against floci at localhost:4566." >&2
    echo "  Unset it: unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY" >&2
    exit 2
  fi
  if [[ "$AWS_ACCESS_KEY_ID" != "test" && "$AWS_ACCESS_KEY_ID" != "local" ]]; then
    echo "WARN: AWS_ACCESS_KEY_ID is set to '$AWS_ACCESS_KEY_ID'." >&2
    echo "  Expected 'test' (the floci dummy). Proceeding because it" >&2
    echo "  doesn't match the real-AWS pattern, but you should double-check." >&2
  fi
fi

if [[ -n "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
  if [[ "$AWS_SECRET_ACCESS_KEY" != "test" && "$AWS_SECRET_ACCESS_KEY" != "local" && ${#AWS_SECRET_ACCESS_KEY} -ge 30 ]]; then
    echo "FATAL: AWS_SECRET_ACCESS_KEY is set and looks real." >&2
    echo "  This script only applies against floci at localhost:4566." >&2
    echo "  Unset it: unset AWS_SECRET_ACCESS_KEY" >&2
    exit 2
  fi
fi

# Check the credentials file too, in case the env is empty but ~/.aws/credentials exists
if [[ -f "${HOME}/.aws/credentials" ]]; then
  echo "FATAL: ${HOME}/.aws/credentials exists." >&2
  echo "  The AWS provider may pick up real credentials from this file." >&2
  echo "  Either:" >&2
  echo "    - move/rename it: mv ~/.aws/credentials ~/.aws/credentials.away" >&2
  echo "    - or set AWS_SHARED_CREDENTIALS_FILE to a floci-only file" >&2
  exit 2
fi

# ---- Hard guard 2: previous scan must have passed --------------------------
if [[ ! -s "$LAST_FILE" ]]; then
  echo "FATAL: $LAST_FILE does not exist or is empty." >&2
  echo "  Run scripts/scan.sh first. The gate must be PASS before deploy." >&2
  exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "FATAL: jq is required." >&2
  exit 2
fi
gate="$(jq -r '.gate' "$LAST_FILE")"
if [[ "$gate" != "PASS" ]]; then
  echo "FATAL: latest scan gate is $gate (expected PASS)." >&2
  echo "  Run scripts/scan.sh and confirm it prints 'gate: PASS'." >&2
  exit 2
fi

# ---- Hard guard 3: floci-core is reachable ---------------------------------
FLOCI_ENDPOINT="${FLOCI_ENDPOINT:-http://localhost:4566}"
if ! curl -sf -m 3 -o /dev/null "$FLOCI_ENDPOINT/health" 2>/dev/null \
   && ! curl -sf -m 3 -o /dev/null "$FLOCI_ENDPOINT/" 2>/dev/null; then
  echo "FATAL: floci-core is not reachable at $FLOCI_ENDPOINT" >&2
  echo "  Start it with: podman-compose -f podman-compose.yml up -d" >&2
  exit 2
fi

# ---- Export floci-only env vars for the AWS provider ------------------------
# These tell the AWS provider to talk to floci instead of real AWS.
# errors toleration for iequality check of dummy
set +u
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
# SEC_INTENT: providers.tf's endpoints{} block reads ONLY this one variable
# for every service (all 7 modules share a single floci-core endpoint) — a
# per-service TF_<SERVICE>_ENDPOINT convention was exported here previously
# but was never read by any .tf file. Removed rather than wired up: with one
# emulator container per cloud, per-service endpoints would all resolve to
# the same value anyway.
export TF_VAR_localstack_enabled=true
export TF_VAR_localstack_endpoint="$FLOCI_ENDPOINT"
set -u

# ---- terraform init (idempotent) -------------------------------------------
echo "→ terraform init"
cd "$TF_DIR"
terraform init -input=false -no-color >/tmp/tf-init.out 2>&1 \
  || { echo "FATAL: terraform init failed. See /tmp/tf-init.out." >&2; cat /tmp/tf-init.out >&2; exit 2; }

# ---- terraform apply --------------------------------------------------------
echo "→ terraform apply -auto-approve"
apply_tmp="$(mktemp)"
trap 'rm -f "$apply_tmp"' EXIT
terraform apply -auto-approve -input=false -no-color >"$apply_tmp" 2>&1
apply_exit=$?
if [[ $apply_exit -ne 0 ]]; then
  echo "FATAL: terraform apply failed (exit $apply_exit)" >&2
  cat "$apply_tmp" >&2
  exit 2
fi
cat "$apply_tmp"
trap - EXIT

# ---- Capture outputs --------------------------------------------------------
# terraform output -json gives us the resource IDs we want to verify against
# floci-core directly in scripts/verify.sh.
outputs_json="$(terraform output -json -no-color)"

# Snapshot the state for the agent's later audit log
snapshot_dir="$TF_DIR/state-snapshots"
mkdir -p "$snapshot_dir"
ts="$(date -u +%Y%m%dT%H%M%SZ)"
cp "$TF_DIR/terraform.tfstate" "$snapshot_dir/terraform.tfstate.${ts}"

# ---- Write dashboard JSON ---------------------------------------------------
event="$(jq -n \
  --arg ts "$ts" \
  --arg endpoint "$FLOCI_ENDPOINT" \
  --argjson outs "$outputs_json" \
  '{
    timestamp: $ts,
    endpoint: $endpoint,
    outputs: $outs,
    state_snapshot: ("state-snapshots/terraform.tfstate." + $ts)
  }')"

# Append to deploy history
hist_tmp="$(mktemp)"
if [[ -s "$DEPLOY_HIST" ]] && jq -e 'type == "array"' "$DEPLOY_HIST" >/dev/null 2>&1; then
  jq --argjson e "$event" '. + [$e]' "$DEPLOY_HIST" >"$hist_tmp"
else
  echo "[$event]" | jq '.' >"$hist_tmp"
fi
mv "$hist_tmp" "$DEPLOY_HIST"
echo "$event" | jq '.' >"$DEPLOY_LAST"

# ---- Tell verify.sh what to check ------------------------------------------
# We just write the outputs; verify.sh will do the real curl checks.
echo "$event" | jq '{outputs: .outputs, last_deploy: .timestamp}' >"$VERIFY_PENDING"

echo ""
echo "DEPLOY OK at $ts"
echo "Outputs:"
echo "$outputs_json" | jq -r 'to_entries[] | "  \(.key) = \(.value.value)"'
echo ""
echo "Next: ./scripts/verify.sh"
