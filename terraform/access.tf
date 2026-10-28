# ---------------------------------------------------------------------------
# Operator access path. The cluster API and the LLM endpoint are both private,
# so humans reach them through a jumpbox fronted by Azure Bastion. No public
# IP is ever attached to a workload. From the jumpbox an operator runs kubectl
# and points CLI clients at the internal LLM load balancer (see scripts/).
# ---------------------------------------------------------------------------

resource "azurerm_public_ip" "bastion" {
  name                = "pip-${var.prefix}-bastion"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_bastion_host" "this" {
  name                = "bas-${var.prefix}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  sku                 = "Standard"
  tunneling_enabled   = true

  ip_configuration {
    name                 = "primary"
    subnet_id            = azurerm_subnet.bastion.id
    public_ip_address_id = azurerm_public_ip.bastion.id
  }

  tags = var.tags
}

resource "azurerm_network_interface" "jumpbox" {
  name                = "nic-${var.prefix}-jump"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name

  ip_configuration {
    name                          = "primary"
    subnet_id                     = azurerm_subnet.aks.id
    private_ip_address_allocation = "Dynamic"
  }
  tags = var.tags
}

resource "azurerm_linux_virtual_machine" "jumpbox" {
  name                = "vm-${var.prefix}-jump"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  size                = "Standard_D2s_v5"
  admin_username      = "azureuser"

  network_interface_ids = [azurerm_network_interface.jumpbox.id]

  # Entra ID login only; no local password. Add the AADSSHLogin extension and
  # assign "Virtual Machine Administrator Login" to operators out-of-band.
  admin_ssh_key {
    username   = "azureuser"
    public_key = file(pathexpand(var.jumpbox_ssh_public_key_path))
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  identity { type = "SystemAssigned" }
  tags = var.tags
}

variable "jumpbox_ssh_public_key_path" {
  description = "Path to the SSH public key authorised on the jumpbox."
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

# Operators need this role to pull cluster credentials against the private API.
resource "azurerm_role_assignment" "jumpbox_cluster_user" {
  scope                = azurerm_kubernetes_cluster.this.id
  role_definition_name = "Azure Kubernetes Service Cluster User Role"
  principal_id         = azurerm_linux_virtual_machine.jumpbox.identity[0].principal_id
}
