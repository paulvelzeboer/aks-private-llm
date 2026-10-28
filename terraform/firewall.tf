# ---------------------------------------------------------------------------
# Egress control. The firewall is the single chokepoint for all node traffic.
#
# Posture: DEFAULT DENY. The only rules present allow the minimum platform
# FQDNs that AKS itself requires to stay healthy (control-plane registration,
# node image/security updates, time). These carry NO workload data — they are
# control-plane plumbing. Everything else, including any attempt by a model or
# gateway pod to reach the internet, hits the implicit deny and is logged.
#
# To go even stricter (pure air-gap), scale this allow set to zero by pointing
# the cluster at a private Mariner/Ubuntu package mirror + private MCR cache in
# ACR, and remove application_rule_collection entirely. See docs/architecture.md.
# ---------------------------------------------------------------------------

resource "azurerm_public_ip" "firewall" {
  name                = "pip-${var.prefix}-fw"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_firewall_policy" "this" {
  name                = "afwp-${var.prefix}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  sku                 = "Standard"

  # Deny and log everything not explicitly matched.
  threat_intelligence_mode = "Deny"
  tags                     = var.tags
}

resource "azurerm_firewall" "this" {
  name                = "afw-${var.prefix}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  sku_name            = "AZFW_VNet"
  sku_tier            = "Standard"
  firewall_policy_id  = azurerm_firewall_policy.this.id

  ip_configuration {
    name                 = "primary"
    subnet_id            = azurerm_subnet.firewall.id
    public_ip_address_id = azurerm_public_ip.firewall.id
  }

  tags = var.tags
}

# Mandatory AKS platform FQDNs. This is the allowlist — nothing else egresses.
resource "azurerm_firewall_policy_rule_collection_group" "aks_platform" {
  name               = "aks-platform"
  firewall_policy_id = azurerm_firewall_policy.this.id
  priority           = 200

  network_rule_collection {
    name     = "aks-platform-network"
    priority = 200
    action   = "Allow"

    rule {
      name                  = "ntp"
      protocols             = ["UDP"]
      source_addresses      = [var.subnet_aks_cidr]
      destination_addresses = ["*"]
      destination_ports     = ["123"]
    }
    rule {
      name                  = "api-udp"
      protocols             = ["UDP"]
      source_addresses      = [var.subnet_aks_cidr]
      destination_addresses = ["AzureCloud.${var.location}"]
      destination_ports     = ["1194"]
    }
    rule {
      name                  = "api-tcp"
      protocols             = ["TCP"]
      source_addresses      = [var.subnet_aks_cidr]
      destination_addresses = ["AzureCloud.${var.location}"]
      destination_ports     = ["9000"]
    }
  }

  application_rule_collection {
    name     = "aks-platform-fqdn"
    priority = 210
    action   = "Allow"

    rule {
      name = "aks-required"
      protocols {
        type = "Https"
        port = 443
      }
      source_addresses  = [var.subnet_aks_cidr]
      destination_fqdns = [
        "*.hcp.${var.location}.azmk8s.io",
        "mcr.microsoft.com",
        "*.data.mcr.microsoft.com",
        "management.azure.com",
        "login.microsoftonline.com",
        "packages.microsoft.com",
        "acs-mirror.azureedge.net",
      ]
    }
  }
}

# Firewall + policy diagnostics -> Log Analytics so every allowed AND denied
# flow is retained and queryable (this is the "monitored" half of the brief).
resource "azurerm_monitor_diagnostic_setting" "firewall" {
  name                       = "diag-firewall"
  target_resource_id         = azurerm_firewall.this.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id

  enabled_log { category_group = "allLogs" }
  metric { category = "AllMetrics" }
}
