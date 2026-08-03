#!/usr/bin/env bash
# =============================================================================
# scripts/toggle-fixture.sh
# =============================================================================
# Purpose
#   Switch between the "fixture present" and "fixture absent" versions of
#   terraform/main.tf, so the demo can show BOTH the gated-fail and the
#   passing deploy without anyone editing Terraform by hand.
#
# Usage
#   ./scripts/toggle-fixture.sh on      # restore the fixture (default start state)
#   ./scripts/toggle-fixture.sh off     # remove the fixture (clean scan)
#   ./scripts/toggle-fixture.sh status  # show current state
#
# Implementation
#   We keep THREE committed files:
#     terraform/main.tf                    currently-active
#     terraform/main.tf.with-fixture      ON state (the deliberate misconfig)
#     terraform/main.tf.without-fixture   OFF state (fixture commented out)
#
#   toggle is implemented by `cp` between them, with a validation step.
#   No sed/python parsing of HCL — cp is deterministic and reversible.
#
#   The OFF state is generated once (see scripts/bootstrap-fixture-snapshots.sh)
#   and committed alongside main.tf. The script does not generate it on
#   demand.
#
# SEC_INTENT: this is the ONLY way the demo is allowed to change terraform
# state. The agent-loop (scripts/agent-loop.sh) is forbidden from doing this.
# Adding a third file and not relying on regex keeps the toggle safe.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$SCRIPT_DIR/../terraform"
TARGET="$TF_DIR/main.tf"
SNAPSHOT_ON="$TF_DIR/main.tf.with-fixture"
SNAPSHOT_OFF="$TF_DIR/main.tf.without-fixture"
TERRAFORM_BIN="${TERRAFORM_BIN:-terraform}"

# --- Refuse to run if any required file is missing ---------------------------
for f in "$TARGET" "$SNAPSHOT_ON" "$SNAPSHOT_OFF"; do
  if [[ ! -f "$f" ]]; then
    echo "FATAL: $f not found." >&2
    echo "  All three files must be committed to the repo:" >&2
    echo "    terraform/main.tf" >&2
    echo "    terraform/main.tf.with-fixture" >&2
    echo "    terraform/main.tf.without-fixture" >&2
    exit 2
  fi
done

# --- The snapshots must contain the right state ------------------------------
if ! grep -qE '^resource "aws_iam_policy" "fixtures_admin"' "$SNAPSHOT_ON"; then
  echo "FATAL: $SNAPSHOT_ON does not contain the fixture resource." >&2
  echo "  The with-fixture snapshot IS the ON state. Restore from git." >&2
  exit 2
fi
if grep -qE '^resource "aws_iam_policy" "fixtures_admin"' "$SNAPSHOT_OFF"; then
  echo "FATAL: $SNAPSHOT_OFF still contains the fixture resource." >&2
  echo "  The without-fixture snapshot must have it commented out." >&2
  exit 2
fi

# --- Detect current state ---------------------------------------------------
if grep -qE '^resource "aws_iam_policy" "fixtures_admin"' "$TARGET"; then
  current_state="on"
else
  current_state="off"
fi

# --- Run --------------------------------------------------------------------
action="${1:-status}"
case "$action" in
  status)
    echo "Fixture state: $current_state"
    if [[ "$current_state" == "on" ]]; then
      echo "  → scripts/scan.sh will FAIL until you run: ./scripts/toggle-fixture.sh off"
    else
      echo "  → scripts/scan.sh will PASS"
    fi
    exit 0
    ;;
  on)  target_state="on";  src="$SNAPSHOT_ON"  ;;
  off) target_state="off"; src="$SNAPSHOT_OFF" ;;
  *)
    echo "Usage: $0 [on|off|status]" >&2
    exit 2
    ;;
esac

if [[ "$current_state" == "$target_state" ]]; then
  echo "Fixture already $target_state — no change."
  exit 0
fi

# --- Do the swap -----------------------------------------------------------
# We copy into a temp file, validate, then atomically move into place.
swap_tmp="$(mktemp)"
trap 'rm -f "$swap_tmp"' EXIT

cp "$src" "$swap_tmp"

# --- Validate before committing -------------------------------------------
echo "Validating Terraform syntax..."
if ! "$TERRAFORM_BIN" -chdir="$TF_DIR" validate -no-color >/tmp/tf-validate.out 2>&1; then
  echo "ERROR: terraform validate failed after toggle. Aborting — file NOT modified." >&2
  cat /tmp/tf-validate.out >&2
  exit 2
fi
echo "Terraform validation OK."

mv "$swap_tmp" "$TARGET"
trap - EXIT

echo "Fixture state: $current_state → $target_state"
echo "Run scripts/scan.sh to see the gate verdict."
