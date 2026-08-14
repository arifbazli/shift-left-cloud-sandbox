# =============================================================================
# modules/azure-compute/main.tf
# =============================================================================
# CONFIRMED GAP AGAINST modules/compute (AWS) — no ECS Fargate / Container
# Apps equivalent exists anywhere in floci-az's documented service list (23
# services, docs/services/*.md). Not built as a placeholder, just absent.
#
# Resources built: VM (mocked, no real container backing — weaker fidelity
# than AWS's EC2, confirmed working on apply), Linux Function App (Functions
# — Lambda equivalent, CONFIRMED BLOCKED, see below), AKS cluster (EKS
# equivalent, CONFIRMED FAILURE, see below).
#
# CONFIRMED FAILURE, ROOT CAUSE ISOLATED (root-caused 2026-08-14,
# superseding an earlier "inconclusive" 2026-08-13 note describing a
# silent 10+ minute hang under that night's image): azurerm_service_plan.
# functions fails immediately, not a hang. Microsoft.Web is not one of
# floci-az's dedicated ARM provider namespaces, so create falls through
# to a generic ArmHandler fallback — confirmed via a direct API probe
# that this fallback creates Microsoft.Web/sites just fine (200 OK) but
# returns 404 ResourceNotFound for a create PUT to Microsoft.Web/
# serverFarms specifically: a gap in floci-az's own fallback handler, not
# a Terraform-side issue. See growth-queue-azure.yaml and CONTEXT.md's
# Research log for the full comparison. Because azurerm_linux_function_
# app.main depends on this service plan, the Function App resource never
# even starts creating — the "0 functions found" code-loading issue
# documented below is now moot/premature; apply never gets far enough to
# reach it. Both kept in code rather than removed — visible-stall-over-
# silent-skip (even though this specific one fails fast, not slow).
#
# CONFIRMED FAILURE (2026-08-13, isolated test, independent of the above):
# azurerm_kubernetes_cluster.main. The netavark/iptables fix (see
# podman-compose.yml) works correctly here — the k3s container is created
# and STARTS (no nftables error). k3s itself then crashes fatally within
# ~1 second: `Error: failed to find cpuset cgroup (v2)` — rootless Podman
# doesn't delegate the cpuset cgroup v2 controller to containers spawned
# via floci-az's Docker-API call. floci-az's own provisioningState never
# leaves "Creating" (it doesn't detect the backing container died), so
# this stalls forever from the ARM API's perspective too, not just
# slowly. Kept in code — same treatment as AWS's aws_eks_cluster.
# =============================================================================

# -----------------------------------------------------------------------------
# Network Interface + Virtual Machine
# SEC_INTENT: mirrors modules/compute's aws_instance.app as far as floci-az
# allows. WEAKER FIDELITY THAN EC2, confirmed via docs/services/vm.md and
# tonight's live banner ("vm [enabled] docker: mocked (no docker)") — floci-az
# VMs default to pure ARM control-plane state: they provision instantly,
# report a synthetic power state, and run no real OS at all (no SSH, no
# guest agent, no actual kernel). This is floci-az's own documented default
# (FLOCI_AZ_SERVICES_VM_MOCKED=true), not a choice this module makes.
# IMDSv2-equivalent hardening doesn't apply — Azure VMs use a different
# metadata model (Azure Instance Metadata Service, not IMDS) that floci-az's
# mocked mode doesn't emulate at all.
# -----------------------------------------------------------------------------
resource "azurerm_network_interface" "app" {
  name                = "floci-app-nic"
  location            = var.location
  resource_group_name = var.resource_group_name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = var.subnet_id
    private_ip_address_allocation = "Dynamic"
  }

  tags = {
    Name = "floci-app-nic"
  }
}

# SEC_INTENT: generated locally for the mocked VM's throwaway admin_ssh_key
# below — floci-az's mocked mode never starts a real OS, so no real key
# material is ever meaningfully "used." Pure local crypto (hashicorp/tls),
# no network calls, no floci-az interaction.
resource "tls_private_key" "app" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "azurerm_linux_virtual_machine" "app" {
  name                = "floci-app-${var.environment}"
  resource_group_name = var.resource_group_name
  location            = var.location
  size                = "Standard_B1s"
  admin_username      = "floci"

  network_interface_ids = [azurerm_network_interface.app.id]

  # SEC_INTENT: SSH key auth, no password auth — mirrors EC2's SSM-managed
  # (no key pair, no password) intent as closely as azurerm's schema allows.
  disable_password_authentication = true
  admin_ssh_key {
    username   = "floci"
    public_key = tls_private_key.app.public_key_openssh
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    # SEC_INTENT: mirrors aws_instance.app's root_block_device.encrypted —
    # Azure managed disks are encrypted at rest by default (platform-managed
    # key), unlike AWS EBS where encryption is opt-in per volume.
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts"
    version   = "latest"
  }

  tags = {
    Name        = "floci-app"
    Environment = var.environment
  }
}

# -----------------------------------------------------------------------------
# Linux Function App
# SEC_INTENT: mirrors modules/compute's aws_lambda_function.main. Creates the
# ARM resource (Microsoft.Web/sites) only — Terraform never deploys function
# CODE for Azure Functions even against real Azure (code deployment is
# always a separate step, e.g. `func azure functionapp publish` or a zip
# deploy), so this is not a gap relative to AWS's Lambda resource so much as
# a real, pre-existing difference in how the two clouds' Terraform providers
# divide infra from code.
#
# SECONDARY, now-moot issue: if function code is ALSO deployed via
# floci-az's own convenience API (POST .../admin/apps/{app}/functions/
# {name}, outside Terraform entirely, same as how real Azure Functions
# code deployment is also outside Terraform), the deployed Azure Functions
# host reports "0 functions found" — confirmed 2026-08-13 during the
# Docker-socket sidecar gate test. Moot for now: see the top-of-file
# CONFIRMED GAP note on azurerm_service_plan.functions — apply never gets
# far enough to reach this Function App resource at all.
# -----------------------------------------------------------------------------
resource "azurerm_service_plan" "functions" {
  name                = "floci-func-plan-${var.environment}"
  resource_group_name = var.resource_group_name
  location            = var.location
  os_type             = "Linux"
  sku_name            = "Y1" # Consumption plan — matches Lambda's serverless billing model

  tags = {
    Name = "floci-func-plan"
  }
}

resource "azurerm_storage_account" "functions" {
  # SEC_INTENT: Azure Functions requires a backing storage account for its
  # own runtime state (triggers, locks) — no AWS Lambda equivalent
  # requirement; a real Azure API constraint, not this module's choice.
  name                     = "flocifuncsa${var.environment}"
  resource_group_name      = var.resource_group_name
  location                 = var.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  min_tls_version          = "TLS1_2"

  tags = {
    Name = "floci-func-sa"
  }

  # SEC_INTENT: same confirmed floci-az response-consistency bug as
  # azure-storage's azurerm_storage_account.main — see that resource's
  # comment for the full explanation. Applied here defensively (not yet
  # separately confirmed on THIS specific storage account, since apply
  # never gets this far — see the CONFIRMED GAP note above on
  # azurerm_service_plan.functions) but the resource type and floci-az's
  # ARM handler are identical, so the same fix is applied preemptively
  # rather than waiting to rediscover it once Service Plan is fixed.
  lifecycle {
    ignore_changes = [queue_encryption_key_type, table_encryption_key_type]
  }
}

resource "azurerm_linux_function_app" "main" {
  name                = "floci-hello-${var.environment}"
  resource_group_name = var.resource_group_name
  location            = var.location

  service_plan_id            = azurerm_service_plan.functions.id
  storage_account_name       = azurerm_storage_account.functions.name
  storage_account_access_key = azurerm_storage_account.functions.primary_access_key

  site_config {}

  tags = {
    Name        = "floci-hello"
    Environment = var.environment
  }
}

# -----------------------------------------------------------------------------
# AKS Cluster
# SEC_INTENT: mirrors modules/compute's aws_eks_cluster.main as closely as
# floci-az's AKS emulation allows. private_cluster_enabled mirrors EKS's
# endpoint_public_access = false (no public API server). floci-az's AKS
# defaults to REAL mode (a genuine rancher/k3s container per cluster, needs
# the Docker socket + the netavark/iptables fix already wired via
# scripts/start-floci-az.sh) — attempted for real here, same rigor as AWS's
# EKS, not defaulted to floci-az's mocked shortcut.
#
# CONFIRMED FAILURE — see the top-of-file note above (cgroups v2 cpuset
# missing under rootless Podman). Kept in code, expected to stall.
# -----------------------------------------------------------------------------
resource "azurerm_kubernetes_cluster" "main" {
  name                = "floci-aks-${var.environment}"
  resource_group_name = var.resource_group_name
  location            = var.location
  dns_prefix          = "floci-aks-${var.environment}"

  private_cluster_enabled           = true # SEC_INTENT: no public API server, mirrors EKS's endpoint_public_access = false
  role_based_access_control_enabled = true # SEC_INTENT: RBAC on — mirrors EKS's IAM-based least-privilege intent (AVD-AZU-0042)

  default_node_pool {
    name           = "default"
    node_count     = 1
    vm_size        = "Standard_DS2_v2"
    vnet_subnet_id = var.subnet_id
  }

  identity {
    type = "SystemAssigned"
  }

  # SEC_INTENT: enforce network policies between pods — mirrors EKS's
  # encryption_config/log-type hardening as "harden it even though apply is
  # confirmed to fail" (AVD-AZU-0043).
  network_profile {
    network_plugin = "azure"
    network_policy = "azure"
  }

  tags = {
    Name        = "floci-aks"
    Environment = var.environment
  }
}
