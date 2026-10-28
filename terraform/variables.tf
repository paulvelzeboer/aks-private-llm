variable "prefix" {
  description = "Short name prefix for all resources."
  type        = string
  default     = "privllm"
}

variable "location" {
  description = "Azure region. Must have the chosen GPU SKU available."
  type        = string
  default     = "westeurope"
}

variable "kubernetes_version" {
  description = "AKS control plane version."
  type        = string
  default     = "1.30"
}

# ---------------------------------------------------------------------------
# Addressing. Non-overlapping /16 split into purpose-built subnets.
# ---------------------------------------------------------------------------
variable "vnet_cidr" {
  type    = string
  default = "10.42.0.0/16"
}

variable "subnet_aks_cidr" {
  description = "System + GPU node pools live here."
  type        = string
  default     = "10.42.0.0/20"
}

variable "subnet_firewall_cidr" {
  description = "Must be named AzureFirewallSubnet, /26 minimum."
  type        = string
  default     = "10.42.16.0/26"
}

variable "subnet_endpoints_cidr" {
  description = "Private endpoints (ACR, storage, key vault)."
  type        = string
  default     = "10.42.17.0/24"
}

variable "subnet_bastion_cidr" {
  description = "Must be named AzureBastionSubnet, /26 minimum."
  type        = string
  default     = "10.42.18.0/26"
}

# ---------------------------------------------------------------------------
# GPU node pool. Default is a single A100 node; scale as needed.
# ---------------------------------------------------------------------------
variable "gpu_node_vm_size" {
  description = "GPU VM SKU. Standard_NC24ads_A100_v4 = 1x A100 80GB."
  type        = string
  default     = "Standard_NC24ads_A100_v4"
}

variable "gpu_node_count" {
  description = "Initial GPU node count."
  type        = number
  default     = 1
}

variable "gpu_min_count" {
  description = "Autoscaler floor. 0 lets the Spot pool scale to zero when idle."
  type        = number
  default     = 0
}

variable "gpu_node_max_count" {
  type    = number
  default = 3
}

variable "gpu_spot_max_price" {
  description = "Max USD/hour for Spot GPU nodes. -1 = pay up to on-demand (recommended; evicts only on capacity, never on price)."
  type        = number
  default     = -1
}

# IP ranges permitted to reach the private endpoint via Bastion/VPN.
# This is the ONLY inbound path; the LLM API is never public.
variable "admin_source_cidr" {
  description = "Operator source range allowed to the jumpbox/Bastion."
  type        = string
  default     = "10.42.0.0/16"
}

variable "tags" {
  type = map(string)
  default = {
    workload   = "private-llm"
    managed-by = "terraform"
    egress     = "air-gapped"
  }
}
