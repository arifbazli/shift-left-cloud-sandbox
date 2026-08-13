# =============================================================================
# modules/azure-network/main.tf
# =============================================================================
# Resources: resource group, VNet, subnet, NSG (+ rules).
# Mirrors modules/network/'s AWS shape (VPC, subnet, SG+rules) as closely as
# floci-az's confirmed service coverage allows. See the flow-logs note below
# for the one thing that does NOT carry over.
# =============================================================================

# -----------------------------------------------------------------------------
# Resource Group
# SEC_INTENT: every azure-* module attaches to this one resource group — real
# Azure practice groups related resources together rather than one RG per
# resource type. Other azure-* modules take resource_group_name/location as
# inputs from this module's outputs, mirroring how modules/network exports
# vpc_id/subnet_id/app_security_group_id for the AWS modules to depend on.
# -----------------------------------------------------------------------------
resource "azurerm_resource_group" "main" {
  name     = "floci-rg-${var.environment}"
  location = "eastus"

  tags = {
    Name        = "floci-rg"
    Environment = var.environment
    Owner       = "shift-left-sandbox"
  }
}

# -----------------------------------------------------------------------------
# Virtual Network + Subnet
# SEC_INTENT: mirrors modules/network's aws_vpc.main + aws_subnet.private.
# Single private-shaped subnet; no public IP association at this layer.
# -----------------------------------------------------------------------------
resource "azurerm_virtual_network" "main" {
  name                = "floci-vnet"
  address_space       = [var.vnet_cidr]
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  tags = {
    Name        = "floci-vnet"
    Environment = var.environment
  }
}

resource "azurerm_subnet" "private" {
  name                 = "floci-private"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [cidrsubnet(var.vnet_cidr, 8, 1)] # 10.0.1.0/24
}

# -----------------------------------------------------------------------------
# Network Security Group + Rules
# SEC_INTENT: mirrors modules/network's aws_security_group.app + its 5 rules.
# Tight by default: SSH/app-port ingress scoped to the VNet CIDR only, no
# 0.0.0.0/0 ingress. Azure NSG rules are single-direction, priority-ordered —
# unlike AWS's aws_security_group_rule, so each AWS rule maps 1:1 to one
# azurerm_network_security_rule with an explicit priority instead of an
# ingress/egress boolean.
# -----------------------------------------------------------------------------
resource "azurerm_network_security_group" "app" {
  name                = "floci-app-nsg"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  tags = {
    Name = "floci-app-nsg"
  }
}

resource "azurerm_subnet_network_security_group_association" "private" {
  subnet_id                 = azurerm_subnet.private.id
  network_security_group_id = azurerm_network_security_group.app.id
}

# SEC_INTENT: ingress is VNet-only on 22, app port 8080 from VNet only —
# same scope as modules/network's ssh_admin + app_internal rules.
resource "azurerm_network_security_rule" "ssh_admin" {
  name                        = "ssh-admin"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "22"
  source_address_prefix       = var.vnet_cidr
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.main.name
  network_security_group_name = azurerm_network_security_group.app.name
  description                 = "SSH from inside the VNet"
}

resource "azurerm_network_security_rule" "app_internal" {
  name                        = "app-internal"
  priority                    = 110
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "8080"
  source_address_prefix       = var.vnet_cidr
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.main.name
  network_security_group_name = azurerm_network_security_group.app.name
  description                 = "App traffic from inside the VNet"
}

# SEC_INTENT: explicit egress restricted to https (443) only — same scope as
# modules/network's egress_https rule.
resource "azurerm_network_security_rule" "egress_https" {
  name                        = "egress-https"
  priority                    = 100
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.main.name
  network_security_group_name = azurerm_network_security_group.app.name
  description                 = "Outbound HTTPS only (for package updates and API calls)"
}

resource "azurerm_network_security_rule" "egress_dns_tcp" {
  name                        = "egress-dns-tcp"
  priority                    = 110
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "53"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.main.name
  network_security_group_name = azurerm_network_security_group.app.name
  description                 = "DNS over TCP"
}

resource "azurerm_network_security_rule" "egress_dns_udp" {
  name                        = "egress-dns-udp"
  priority                    = 120
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Udp"
  source_port_range           = "*"
  destination_port_range      = "53"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.main.name
  network_security_group_name = azurerm_network_security_group.app.name
  description                 = "DNS over UDP"
}

# -----------------------------------------------------------------------------
# Flow logs — CONFIRMED GAP, not built
# -----------------------------------------------------------------------------
# AWS's modules/network provisions aws_flow_log.main plus a dedicated S3
# bucket and IAM role for it. Azure's real equivalent is NSG Flow Logs (part
# of Network Watcher, azurerm_network_watcher_flow_log). floci-az's network
# service docs (docs/services/network.md) explicitly enumerate its full
# scope — VNet, subnets, NIC, public IP, NSG, load balancers, application
# gateways, private DNS zones, private endpoints, private link services —
# and Network Watcher / flow logs is not among them. Confirmed absent, not
# an oversight: this module intentionally has no flow-log resource. See
# CONTEXT.md for the full gap list against AWS's module set.
