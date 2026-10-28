terraform {
  required_version = ">= 1.6.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.0"
    }
  }

  # Remote state is strongly recommended for a controlled environment.
  # Create the storage account out-of-band, then uncomment:
  #
  # backend "azurerm" {
  #   resource_group_name  = "rg-tfstate"
  #   storage_account_name = "sttfstateprivllm"
  #   container_name       = "tfstate"
  #   key                  = "private-llm.tfstate"
  # }
}

provider "azurerm" {
  features {}
}

provider "azapi" {}
