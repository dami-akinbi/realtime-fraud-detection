terraform {
  required_version = ">= 1.6.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.100"
    }
  }

  backend "azurerm" {
    resource_group_name  = "rg-tfstate-shared"
    storage_account_name = "sttfstatedamiakinbi"
    container_name       = "tfstate"
    key                  = "fraud-detection-dev.tfstate"
  }
}

provider "azurerm" {
  features {}
}
