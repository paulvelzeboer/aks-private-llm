resource "azurerm_log_analytics_workspace" "this" {
  name                = "law-${var.prefix}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  sku                 = "PerGB2018"
  retention_in_days   = 90
  tags                = var.tags
}

resource "azurerm_user_assigned_identity" "aks" {
  name                = "id-${var.prefix}-aks"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = var.tags
}

# The cluster identity must be able to write routes/associate the UDR subnet.
resource "azurerm_role_assignment" "aks_network" {
  scope                = azurerm_resource_group.this.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.aks.principal_id
}

resource "azurerm_kubernetes_cluster" "this" {
  name                = "aks-${var.prefix}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  dns_prefix          = "${var.prefix}-priv"
  kubernetes_version  = var.kubernetes_version
  node_resource_group = "rg-${var.prefix}-nodes"

  # Private API server: control plane has no public endpoint.
  private_cluster_enabled             = true
  private_cluster_public_fqdn_enabled = false
  local_account_disabled              = true

  azure_active_directory_role_based_access_control {
    azure_rbac_enabled = true
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.aks.id]
  }

  # System pool: small, CPU-only, runs ingress/gateway/observability.
  default_node_pool {
    name                 = "system"
    vm_size              = "Standard_D4s_v5"
    auto_scaling_enabled = true
    min_count            = 2
    max_count            = 3
    vnet_subnet_id       = azurerm_subnet.aks.id
    orchestrator_version = var.kubernetes_version
    only_critical_addons_enabled = true
    upgrade_settings {
      max_surge = "33%"
    }
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_policy      = "cilium"
    network_data_plane  = "cilium"
    load_balancer_sku   = "standard"
    # The decisive setting: no managed outbound. All egress follows the UDR.
    outbound_type = "userDefinedRouting"
    service_cidr  = "172.16.0.0/16"
    dns_service_ip = "172.16.0.10"
  }

  oms_agent {
    log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id
  }

  # Managed Prometheus: the ama-metrics agent scrapes cluster + app targets
  # and ships them to the Azure Monitor workspace (see monitoring.tf).
  monitor_metrics {}

  microsoft_defender {
    log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id
  }

  workload_identity_enabled = true
  oidc_issuer_enabled       = true

  tags = var.tags

  # The UDR must exist before the cluster, or egress bootstrap fails.
  depends_on = [
    azurerm_subnet_route_table_association.aks,
    azurerm_firewall.this,
    azurerm_firewall_policy_rule_collection_group.aks_platform,
  ]

  lifecycle {
    ignore_changes = [default_node_pool[0].node_count]
  }
}

# GPU pool: tainted so only the model server lands here. Nodes are labelled
# for the NVIDIA device plugin / GPU operator (see kubernetes/base).
resource "azurerm_kubernetes_cluster_node_pool" "gpu" {
  name                  = "gpu"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.this.id
  vm_size               = var.gpu_node_vm_size
  auto_scaling_enabled  = true
  node_count            = var.gpu_node_count
  min_count             = var.gpu_node_count
  max_count             = var.gpu_node_max_count
  vnet_subnet_id        = azurerm_subnet.aks.id
  orchestrator_version  = var.kubernetes_version
  os_disk_size_gb       = 256

  node_labels = {
    "workload" = "llm"
    "accelerator" = "nvidia"
  }
  node_taints = ["nvidia.com/gpu=present:NoSchedule"]

  tags = var.tags

  lifecycle {
    ignore_changes = [node_count]
  }
}
