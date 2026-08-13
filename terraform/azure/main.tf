# =============================================================================
# terraform/azure/main.tf — root module (module calls only)
# =============================================================================
# This file wires the azure-* feature modules together. There are NO inline
# resource blocks here — all resources live in ../modules/azure-*/, mirroring
# terraform/main.tf's AWS shape. Separate state from terraform/ — see
# providers.tf's PURPOSE comment for why.
# =============================================================================

# ── azure-network ────────────────────────────────────────────────────────────
module "azure-network" {
  source      = "../modules/azure-network"
  environment = var.environment
}

# ── azure-storage ────────────────────────────────────────────────────────────
module "azure-storage" {
  source              = "../modules/azure-storage"
  environment         = var.environment
  resource_group_name = module.azure-network.resource_group_name
  location            = module.azure-network.location
}

# ── azure-security ───────────────────────────────────────────────────────────
module "azure-security" {
  source              = "../modules/azure-security"
  environment         = var.environment
  resource_group_name = module.azure-network.resource_group_name
  location            = module.azure-network.location
}

# ── azure-compute ────────────────────────────────────────────────────────────
module "azure-compute" {
  source              = "../modules/azure-compute"
  environment         = var.environment
  resource_group_name = module.azure-network.resource_group_name
  location            = module.azure-network.location
  subnet_id           = module.azure-network.private_subnet_id
}
