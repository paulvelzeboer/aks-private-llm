# ---------------------------------------------------------------------------
# Managed Prometheus + Managed Grafana. Metrics stay inside Azure: the in-cluster
# ama-metrics agent (enabled by monitor_metrics {} on the cluster) scrapes
# targets and writes to an Azure Monitor workspace; Managed Grafana reads from
# that workspace. No public scrape endpoints, no self-hosted TSDB.
#
# Flow:  ama-metrics (cluster) --> DCR --> Azure Monitor workspace --> Grafana
# ---------------------------------------------------------------------------

resource "azurerm_monitor_workspace" "prometheus" {
  name                = "amw-${var.prefix}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tags                = var.tags
}

# Data collection endpoint + rule that route the cluster's Prometheus stream
# into the monitor workspace, then associate the rule with the cluster.
resource "azurerm_monitor_data_collection_endpoint" "prometheus" {
  name                = "dce-${var.prefix}-prom"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  kind                = "Linux"
  tags                = var.tags
}

resource "azurerm_monitor_data_collection_rule" "prometheus" {
  name                        = "dcr-${var.prefix}-prom"
  resource_group_name         = azurerm_resource_group.this.name
  location                    = azurerm_resource_group.this.location
  data_collection_endpoint_id = azurerm_monitor_data_collection_endpoint.prometheus.id
  kind                        = "Linux"

  destinations {
    monitor_account {
      monitor_account_id = azurerm_monitor_workspace.prometheus.id
      name               = "MonitoringAccount1"
    }
  }

  data_flow {
    streams      = ["Microsoft-PrometheusMetrics"]
    destinations = ["MonitoringAccount1"]
  }

  data_sources {
    prometheus_forwarder {
      streams = ["Microsoft-PrometheusMetrics"]
      name    = "PrometheusDataSource"
    }
  }

  tags = var.tags
}

resource "azurerm_monitor_data_collection_rule_association" "prometheus" {
  name                    = "dcra-${var.prefix}-prom"
  target_resource_id      = azurerm_kubernetes_cluster.this.id
  data_collection_rule_id = azurerm_monitor_data_collection_rule.prometheus.id
}

# ---------------------------------------------------------------------------
# Managed Grafana. Private only: public network access off, reachable from the
# VNet via the jumpbox/Bastion like every other surface here.
# ---------------------------------------------------------------------------
resource "azurerm_dashboard_grafana" "this" {
  name                              = "graf-${var.prefix}"
  resource_group_name               = azurerm_resource_group.this.name
  location                          = azurerm_resource_group.this.location
  grafana_major_version             = 11
  api_key_enabled                   = true
  deterministic_outbound_ip_enabled = false
  public_network_access_enabled     = false

  identity { type = "SystemAssigned" }

  azure_monitor_workspace_integrations {
    resource_id = azurerm_monitor_workspace.prometheus.id
  }

  tags = var.tags
}

# Grafana's identity must be able to read the Prometheus workspace...
resource "azurerm_role_assignment" "grafana_prometheus_reader" {
  scope                = azurerm_monitor_workspace.prometheus.id
  role_definition_name = "Monitoring Data Reader"
  principal_id         = azurerm_dashboard_grafana.this.identity[0].principal_id
}

# ...and reading Container Insights / resource metrics is handy for AKS panels.
resource "azurerm_role_assignment" "grafana_monitoring_reader" {
  scope                = azurerm_resource_group.this.id
  role_definition_name = "Monitoring Reader"
  principal_id         = azurerm_dashboard_grafana.this.identity[0].principal_id
}

# Grant an operator Grafana Admin so they can log in and import the dashboard.
variable "grafana_admin_object_id" {
  description = "Entra object ID to grant Grafana Admin. Empty = skip (assign later)."
  type        = string
  default     = ""
}

resource "azurerm_role_assignment" "grafana_admin" {
  count                = var.grafana_admin_object_id == "" ? 0 : 1
  scope                = azurerm_dashboard_grafana.this.id
  role_definition_name = "Grafana Admin"
  principal_id         = var.grafana_admin_object_id
}
