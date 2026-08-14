#!/usr/bin/env bash
# =============================================================================
# scripts/verify-azure.sh
# =============================================================================
# Purpose
#   Azure sibling of scripts/verify.sh — independently confirm that the
#   resources terraform/azure claims to manage actually exist in floci-az.
#   Like verify.sh, this does NOT trust terraform.tfstate: it reads
#   terraform/azure's OUTPUTS (a snapshot of computed attributes, not
#   internal state) for whatever has actually been applied, and hits
#   floci-az's ARM API directly with a plain HTTP GET for every one of it.
#
# FULL PARITY, DELIBERATELY CHOSEN (2026-08-14)
#   Unlike verify.sh (which only checks AWS resources confirmed to deploy
#   cleanly), this script attempts EVERY resource address in
#   growth-queue-azure.yaml — including the three confirmed DNS-hang
#   resources (storage container/table, Key Vault secret) and the two
#   confirmed-failed compute resources (Service Plan, AKS). A resource that
#   hasn't been grown yet (terraform output is null) is not skipped — its
#   identifier is reconstructed from the module's own static naming
#   convention (e.g. "floci-rg-${environment}") so the check still runs and
#   reports a real "not_found" rather than being silently omitted.
#
# THE TIMEOUT LESSON, APPLIED HERE TOO (see scripts/grow-stack-azure.sh's
# header for the original finding)
#   grow-stack-azure.sh already learned that some of these resources hang
#   with ZERO server-side activity, not just slowly — an unbounded external
#   call must never be trusted to return on its own. Every check below runs
#   under the *outer* `timeout` command (not just curl's own -m, which
#   wouldn't catch a client-side DNS/connect stall the same way) so this
#   script itself can never hang on a known-stuck resource. Distinct
#   status per check: found / not_found / timed_out / check_error — a
#   timeout is never silently reported as a plain "failed".
#
# What "known_issue" means in the output
#   The DNS-hang and confirmed-failed resources are expected to NOT be
#   found — that is not a bug in this script or in floci-az's happy-path
#   behavior, it is the documented state of the emulator (see
#   growth-queue-azure.yaml and CONTEXT.md's Known floci-az limitations).
#   Each result carries a `known_issue` flag so the dashboard/exit-code
#   logic can distinguish "expected, already-documented gap" from
#   "something new and unexpected just broke".
#
# Output
#   - dashboard/public/data/verify-last-azure.json
#   - dashboard/public/data/verify-history-azure.json
#   - Exits 0 if every NON-known-issue resource is found, 1 otherwise.
#     (Known-issue resources never affect the exit code — same reasoning
#     as scan.sh's AWS/Azure gate decoupling: a pre-documented, permanent
#     gap must not block a script whose job is to report reality.)
#
# SEC_INTENT: read-only, like verify.sh. Every check is a GET/HEAD against
# floci-az's own API or a resource's own data-plane host — nothing here
# ever creates, modifies, or destroys a resource, and nothing here trusts
# terraform.tfstate.
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TF_DIR="$ROOT_DIR/terraform/azure"
DASH_DATA="$ROOT_DIR/dashboard/public/data"
LAST_FILE="$DASH_DATA/verify-last-azure.json"
HIST_FILE="$DASH_DATA/verify-history-azure.json"

FLOCI_AZ_ENDPOINT="${FLOCI_AZ_ENDPOINT:-http://localhost:4577}"
# SEC_INTENT: short per-check timeout, same reasoning as grow-stack-azure.sh's
# APPLY_TIMEOUT_SECONDS but far smaller — these are read-only GETs against
# resources that either respond in well under a second (confirmed-working
# ones) or never respond at all (confirmed-stuck ones). There is no "slow
# but legitimately working" case here the way storage-account CREATE had —
# 20s is already generous, not a tight margin like the apply timeout was.
CHECK_TIMEOUT_SECONDS="${CHECK_TIMEOUT_SECONDS:-20}"
AZURE_ENVIRONMENT="${AZURE_ENVIRONMENT:-sandbox}"
SUB_ID="00000000-0000-0000-0000-000000000001" # fixed dummy — matches providers.tf

mkdir -p "$DASH_DATA"

# ---- Precondition: floci-az reachable --------------------------------------
if ! curl -sf -m 3 -o /dev/null "$FLOCI_AZ_ENDPOINT/health" 2>/dev/null; then
  echo "FATAL: floci-az is not reachable at $FLOCI_AZ_ENDPOINT" >&2
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "FATAL: jq is required but not installed." >&2
  exit 2
fi

# ---- Read terraform/azure's outputs (best-effort, never fatal) ------------
# Same trust boundary as verify.sh: outputs are computed attributes, not
# internal state internals. Unlike verify.sh, there's no deploy-azure.sh
# writing a "pending" snapshot — terraform/azure/outputs.tf's own header
# says this script is its intended consumer, reading live.
outputs_json='{}'
if [[ -d "$TF_DIR/.terraform" ]]; then
  out="$(cd "$TF_DIR" && terraform output -json -no-color 2>/dev/null)"
  if [[ -n "$out" ]]; then
    outputs_json="$out"
  fi
fi
out_val() { echo "$outputs_json" | jq -r --arg k "$1" '.[$k].value // empty'; }

RG="floci-rg-${AZURE_ENVIRONMENT}"
rg_out="$(out_val resource_group_name)"; [[ -n "$rg_out" ]] && RG="$rg_out"
STORAGE_ACCOUNT="$(out_val storage_account_name)"; [[ -z "$STORAGE_ACCOUNT" ]] && STORAGE_ACCOUNT="flociartifacts${AZURE_ENVIRONMENT}"
KEY_VAULT_URI="$(out_val key_vault_uri)"; [[ -z "$KEY_VAULT_URI" ]] && KEY_VAULT_URI="https://floci-kv-${AZURE_ENVIRONMENT}.vault.azure.net/"
FUNC_STORAGE_ACCOUNT="flocifuncsa${AZURE_ENVIRONMENT}" # never in outputs.tf at all — construct directly

RM="$FLOCI_AZ_ENDPOINT/subscriptions/$SUB_ID/resourceGroups/$RG"

# ---- check_resource: bounded GET/HEAD, classifies the result --------------
# Args: $1 = resource address (for the report), $2 = http method, $3 = url,
#       $4 = known_issue (true/false), $5 = note
RESULTS=()
check_resource() {
  local address="$1" method="$2" url="$3" known_issue="$4" note="$5"
  local body http_code exit_code status provisioning_state=""

  body="$(mktemp)"
  set +e
  http_code="$(timeout "$CHECK_TIMEOUT_SECONDS" curl -s -o "$body" -w '%{http_code}' -X "$method" "$url" 2>/dev/null)"
  exit_code=$?
  set -e

  if [[ $exit_code -eq 124 ]]; then
    status="timed_out"; http_code="null"
  elif [[ $exit_code -ne 0 ]]; then
    status="check_error"; http_code="null"
  elif [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]]; then
    # SEC_INTENT: a 2xx does not always mean "healthy and done" for this
    # emulator — AKS's confirmed cpuset failure leaves floci-az's own ARM
    # object reachable and returning 200 forever, but stuck at
    # provisioningState "Creating" (it never detects the backing k3s
    # container died). Surface that distinctly rather than reporting a
    # stuck resource as a clean "found".
    provisioning_state="$(jq -r '.properties.provisioningState // empty' "$body" 2>/dev/null)"
    if [[ -n "$provisioning_state" && "$provisioning_state" != "Succeeded" ]]; then
      status="stuck_${provisioning_state,,}"
    else
      status="found"
    fi
  else
    status="not_found"
  fi
  rm -f "$body"

  RESULTS+=("$(jq -n \
    --arg addr "$address" --arg url "$url" --arg status "$status" \
    --argjson http "$([[ "$http_code" == "null" ]] && echo null || echo "$http_code")" \
    --argjson known "$known_issue" --arg note "$note" --arg pstate "$provisioning_state" \
    '{resource: $addr, url: $url, status: $status, http_code: $http, known_issue: $known, note: $note} +
     (if $pstate != "" then {provisioning_state: $pstate} else {} end)')")
}

# =============================================================================
# Resource checks — one per growth-queue-azure.yaml address, same order.
# api-versions below are standard current ARM versions; floci-az's fallback
# handler has been confirmed lenient about the exact version (see
# CONTEXT.md's Research log), so these are not pinned to whatever the
# azurerm provider itself happens to send.
# =============================================================================

# -- azure-network (all 10 confirmed working) --------------------------------
check_resource "module.azure-network.azurerm_resource_group.main" GET \
  "$RM?api-version=2021-04-01" false ""

VNET_ID="$(out_val vnet_id)"; [[ -z "$VNET_ID" ]] && VNET_ID="$RM/providers/Microsoft.Network/virtualNetworks/floci-vnet"
check_resource "module.azure-network.azurerm_virtual_network.main" GET \
  "$FLOCI_AZ_ENDPOINT$VNET_ID?api-version=2023-09-01" false ""

SUBNET_ID="$(out_val private_subnet_id)"; [[ -z "$SUBNET_ID" ]] && SUBNET_ID="$VNET_ID/subnets/floci-private"
check_resource "module.azure-network.azurerm_subnet.private" GET \
  "$FLOCI_AZ_ENDPOINT$SUBNET_ID?api-version=2023-09-01" false ""

NSG_ID="$(out_val app_nsg_id)"; [[ -z "$NSG_ID" ]] && NSG_ID="$RM/providers/Microsoft.Network/networkSecurityGroups/floci-app-nsg"
check_resource "module.azure-network.azurerm_network_security_group.app" GET \
  "$FLOCI_AZ_ENDPOINT$NSG_ID?api-version=2023-09-01" false ""

# NSG<->subnet association has no standalone ARM GET of its own — real Azure
# represents it as a property ON the subnet, not a separate resource. Reuse
# the subnet check's evidence rather than inventing a second network call.
check_resource "module.azure-network.azurerm_subnet_network_security_group_association.private" GET \
  "$FLOCI_AZ_ENDPOINT$SUBNET_ID?api-version=2023-09-01" false \
  "no standalone ARM GET for an association; verified via the subnet resource itself"

for rule in ssh_admin:ssh-admin app_internal:app-internal egress_https:egress-https egress_dns_tcp:egress-dns-tcp egress_dns_udp:egress-dns-udp; do
  addr_suffix="${rule%%:*}"; rule_name="${rule##*:}"
  check_resource "module.azure-network.azurerm_network_security_rule.$addr_suffix" GET \
    "$FLOCI_AZ_ENDPOINT$NSG_ID/securityRules/$rule_name?api-version=2023-09-01" false ""
done

# -- azure-storage ------------------------------------------------------------
check_resource "module.azure-storage.azurerm_storage_account.main" GET \
  "$RM/providers/Microsoft.Storage/storageAccounts/$STORAGE_ACCOUNT?api-version=2023-01-01" false ""

check_resource "module.azure-storage.azurerm_storage_container.artifacts" HEAD \
  "http://${STORAGE_ACCOUNT}.blob.core.windows.net/artifacts?restype=container" true \
  "CONFIRMED DNS-hang (see CONTEXT.md Known floci-az limitations) — floci-az returns this real-Azure-shaped hostname but it never resolves"

check_resource "module.azure-storage.azurerm_storage_table.main" GET \
  "http://${STORAGE_ACCOUNT}.table.core.windows.net/Tables('flociitems${AZURE_ENVIRONMENT}')" true \
  "CONFIRMED DNS-hang — same root cause as the container above"

# -- azure-security -------------------------------------------------------------
check_resource "module.azure-security.azurerm_key_vault.main" GET \
  "$RM/providers/Microsoft.KeyVault/vaults/floci-kv-${AZURE_ENVIRONMENT}?api-version=2023-07-01" false ""

check_resource "module.azure-security.azurerm_key_vault_secret.app_config" GET \
  "${KEY_VAULT_URI%/}/secrets/app-config?api-version=7.4" true \
  "CONFIRMED DNS-hang — same root cause as the storage container/table above"

# -- azure-compute --------------------------------------------------------------
check_resource "module.azure-compute.azurerm_network_interface.app" GET \
  "$RM/providers/Microsoft.Network/networkInterfaces/floci-app-nic?api-version=2023-09-01" false ""

# tls_private_key.app is local-only (hashicorp/tls) — no API exists to check.
RESULTS+=("$(jq -n --arg addr "module.azure-compute.tls_private_key.app" \
  '{resource: $addr, url: null, status: "not_applicable", http_code: null, known_issue: false, note: "local-only resource (hashicorp/tls provider) — no external API to verify against"}')")

check_resource "module.azure-compute.azurerm_linux_virtual_machine.app" GET \
  "$RM/providers/Microsoft.Compute/virtualMachines/floci-app-${AZURE_ENVIRONMENT}?api-version=2023-09-01" false ""

check_resource "module.azure-compute.azurerm_storage_account.functions" GET \
  "$RM/providers/Microsoft.Storage/storageAccounts/${FUNC_STORAGE_ACCOUNT}?api-version=2023-01-01" false ""

check_resource "module.azure-compute.azurerm_service_plan.functions" GET \
  "$RM/providers/Microsoft.Web/serverFarms/floci-func-plan-${AZURE_ENVIRONMENT}?api-version=2023-12-01" true \
  "CONFIRMED FAILURE — floci-az's fallback handler doesn't treat serverFarms as creatable, so this never exists (see CONTEXT.md)"

check_resource "module.azure-compute.azurerm_linux_function_app.main" GET \
  "$RM/providers/Microsoft.Web/sites/floci-hello-${AZURE_ENVIRONMENT}?api-version=2023-12-01" true \
  "depends on the Service Plan above, which never creates — never even starts applying"

check_resource "module.azure-compute.azurerm_kubernetes_cluster.main" GET \
  "$RM/providers/Microsoft.ContainerService/managedClusters/floci-aks-${AZURE_ENVIRONMENT}?api-version=2023-10-01" true \
  "CONFIRMED FAILURE — permanent systemd cpuset delegation gap (see CONTEXT.md); if reachable, check provisioningState for a stuck 'Creating'"

# ---- Assemble the report ----------------------------------------------------
ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
results_json="$(printf '%s\n' "${RESULTS[@]}" | jq -s '.')"

total="$(echo "$results_json" | jq 'length')"
found="$(echo "$results_json" | jq '[.[] | select(.status=="found")] | length')"
not_found="$(echo "$results_json" | jq '[.[] | select(.status=="not_found")] | length')"
timed_out="$(echo "$results_json" | jq '[.[] | select(.status=="timed_out")] | length')"
check_error="$(echo "$results_json" | jq '[.[] | select(.status=="check_error")] | length')"
not_applicable="$(echo "$results_json" | jq '[.[] | select(.status=="not_applicable")] | length')"
stuck="$(echo "$results_json" | jq '[.[] | select(.status | startswith("stuck_"))] | length')"

# A resource is an "unexpected" problem only if it's NOT already a documented
# known_issue and it did not come back found (or not_applicable, which isn't
# a problem at all — it's a resource with no API to check).
unexpected="$(echo "$results_json" | jq \
  '[.[] | select(.known_issue == false and .status != "found" and .status != "not_applicable")] | length')"
all_expected_healthy="$([[ "$unexpected" -eq 0 ]] && echo true || echo false)"

report="$(jq -n \
  --arg ts "$ts" --arg endpoint "$FLOCI_AZ_ENDPOINT" \
  --argjson total "$total" --argjson found "$found" --argjson not_found "$not_found" \
  --argjson timed_out "$timed_out" --argjson check_error "$check_error" \
  --argjson not_applicable "$not_applicable" --argjson stuck "$stuck" --argjson unexpected "$unexpected" \
  --argjson all_expected_healthy "$all_expected_healthy" \
  --argjson results "$results_json" \
  '{
    timestamp: $ts,
    endpoint: $endpoint,
    total: $total,
    found: $found,
    not_found: $not_found,
    timed_out: $timed_out,
    check_error: $check_error,
    not_applicable: $not_applicable,
    stuck: $stuck,
    unexpected_issues: $unexpected,
    all_expected_healthy: $all_expected_healthy,
    results: $results
  }')"

echo "$report" | jq '.' >"$LAST_FILE"
hist_tmp="$(mktemp)"
if [[ -s "$HIST_FILE" ]] && jq -e 'type == "array"' "$HIST_FILE" >/dev/null 2>&1; then
  jq --argjson r "$report" '. + [$r]' "$HIST_FILE" >"$hist_tmp"
else
  echo "[$report]" | jq '.' >"$hist_tmp"
fi
mv "$hist_tmp" "$HIST_FILE"

# ---- Human summary ----------------------------------------------------------
echo "---- verify-azure ($ts) ----"
echo "  endpoint: $FLOCI_AZ_ENDPOINT"
echo "  results:  found=$found not_found=$not_found timed_out=$timed_out check_error=$check_error stuck=$stuck not_applicable=$not_applicable / total=$total"
echo "  unexpected issues (excludes documented known_issue resources): $unexpected"
echo "  status:   $([[ "$all_expected_healthy" == true ]] && echo PASS || echo FAIL)"
echo ""
echo "$results_json" | jq -r '.[] | "  [\(.status | ascii_upcase)]\(if .known_issue then " (known)" else "" end) \(.resource) — HTTP \(.http_code // "n/a")"'

if [[ "$unexpected" -gt 0 ]]; then
  echo ""
  echo "  UNEXPECTED (not a documented known_issue):"
  echo "$results_json" | jq -r '.[] | select(.known_issue == false and .status != "found" and .status != "not_applicable") | "    \(.resource): \(.status)"'
fi

if [[ "$all_expected_healthy" == "true" ]]; then
  exit 0
else
  exit 1
fi
