#!/usr/bin/env bash
# =============================================================================
# scripts/toggle-fixture-azure.sh
# =============================================================================
# Purpose
#   Switch between the "fixture present" and "fixture absent" versions of
#   terraform/modules/azure-security/main.tf — the Azure sibling of
#   scripts/toggle-fixture.sh (AWS). Separate script, not parametrized,
#   matching this repo's established convention: the two fixtures are
#   independent and don't share a toggle mechanism.
#
# Usage
#   ./scripts/toggle-fixture-azure.sh on      # restore the fixture (default start state)
#   ./scripts/toggle-fixture-azure.sh off     # remove the fixture (clean scan)
#   ./scripts/toggle-fixture-azure.sh status  # show current state
#
# Implementation
#   Three committed files, exactly like the AWS toggle:
#     terraform/modules/azure-security/main.tf                  currently-active
#     terraform/modules/azure-security/main.tf.with-fixture     ON state
#     terraform/modules/azure-security/main.tf.without-fixture  OFF state
#
#   INVERTED presence-check vs AWS: AWS's fixture ON means an extra resource
#   is PRESENT. This fixture is an omission inside an EXISTING resource
#   (azurerm_key_vault.main is missing a network_acls block) — so fixture ON
#   means network_acls is ABSENT, fixture OFF means it's PRESENT.
#
#   Validates against terraform/azure (the separate Azure root — see
#   terraform/azure/providers.tf), not terraform/ (AWS).
#
# SEC_INTENT: this is the ONLY way the Azure fixture is allowed to change.
# scripts/agent-loop.sh and scripts/grow-stack-azure.sh are forbidden from
# doing this. No sed/regex on HCL — cp between committed snapshots is
# deterministic and reversible, same reasoning as the AWS toggle.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$SCRIPT_DIR/../terraform/azure"
TARGET="$SCRIPT_DIR/../terraform/modules/azure-security/main.tf"
SNAPSHOT_ON="$SCRIPT_DIR/../terraform/modules/azure-security/main.tf.with-fixture"
SNAPSHOT_OFF="$SCRIPT_DIR/../terraform/modules/azure-security/main.tf.without-fixture"
TERRAFORM_BIN="${TERRAFORM_BIN:-terraform}"

# --- Refuse to run if any required file is missing ---------------------------
for f in "$TARGET" "$SNAPSHOT_ON" "$SNAPSHOT_OFF"; do
  if [[ ! -f "$f" ]]; then
    echo "FATAL: $f not found." >&2
    echo "  All three files must be committed to the repo:" >&2
    echo "    terraform/modules/azure-security/main.tf" >&2
    echo "    terraform/modules/azure-security/main.tf.with-fixture" >&2
    echo "    terraform/modules/azure-security/main.tf.without-fixture" >&2
    exit 2
  fi
done

# --- The snapshots must contain the right state -------------------------------
# NOTE: inverted vs AWS's toggle-fixture.sh — see the header comment above.
if grep -qE '^\s*network_acls\s*\{' "$SNAPSHOT_ON"; then
  echo "FATAL: $SNAPSHOT_ON has a network_acls block — that's the OFF (secure) shape." >&2
  echo "  The with-fixture snapshot IS the ON (vulnerable, no network_acls) state." >&2
  exit 2
fi
if ! grep -qE '^\s*network_acls\s*\{' "$SNAPSHOT_OFF"; then
  echo "FATAL: $SNAPSHOT_OFF is missing a network_acls block." >&2
  echo "  The without-fixture snapshot must have network_acls present (the secure shape)." >&2
  exit 2
fi

# --- Detect current state ----------------------------------------------------
if grep -qE '^\s*network_acls\s*\{' "$TARGET"; then
  current_state="off"
else
  current_state="on"
fi

# --- Run ----------------------------------------------------------------------
action="${1:-status}"
case "$action" in
  status)
    echo "Azure fixture state: $current_state"
    if [[ "$current_state" == "on" ]]; then
      echo "  → AVD-AZU-0013 (CRITICAL) is present until you run: ./scripts/toggle-fixture-azure.sh off"
    else
      echo "  → network_acls is set — AVD-AZU-0013 will not fire"
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
  echo "Azure fixture already $target_state — no change."
  exit 0
fi

# --- Do the swap ---------------------------------------------------------------
swap_tmp="$(mktemp)"
trap 'rm -f "$swap_tmp"' EXIT

cp "$src" "$swap_tmp"

echo "Validating Terraform syntax..."
if ! "$TERRAFORM_BIN" -chdir="$TF_DIR" validate -no-color >/tmp/tf-validate-azure.out 2>&1; then
  echo "ERROR: terraform validate failed after toggle. Aborting — file NOT modified." >&2
  cat /tmp/tf-validate-azure.out >&2
  exit 2
fi
echo "Terraform validation OK."

mv "$swap_tmp" "$TARGET"
trap - EXIT

echo "Azure fixture state: $current_state → $target_state"
echo "Run scripts/scan.sh to see the gate verdict (writes tfsec-azure-last.json)."
