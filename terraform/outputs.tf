output "resource_group" {
  value = azurerm_resource_group.this.name
}

output "aks_name" {
  value = azurerm_kubernetes_cluster.this.name
}

output "acr_login_server" {
  value = azurerm_container_registry.this.login_server
}

output "models_storage_account" {
  value = azurerm_storage_account.models.name
}

output "models_container" {
  value = azurerm_storage_container.weights.name
}

output "log_analytics_workspace_id" {
  value = azurerm_log_analytics_workspace.this.id
}

output "firewall_private_ip" {
  value = azurerm_firewall.this.ip_configuration[0].private_ip_address
}

output "jumpbox_name" {
  value = azurerm_linux_virtual_machine.jumpbox.name
}

output "grafana_endpoint" {
  description = "Managed Grafana URL (reachable from inside the VNet)."
  value       = azurerm_dashboard_grafana.this.endpoint
}

output "monitor_workspace_id" {
  value = azurerm_monitor_workspace.prometheus.id
}

output "get_credentials_cmd" {
  description = "Run from the jumpbox (via Bastion) to get kubectl access."
  value       = "az aks get-credentials --resource-group ${azurerm_resource_group.this.name} --name ${azurerm_kubernetes_cluster.this.name}"
}
