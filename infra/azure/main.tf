resource "azurerm_resource_group" "fraud_rg" {
  name     = "rg-fraud-${var.environment}"
  location = var.location

  tags = {
    project     = "realtime-fraud-detection"
    environment = var.environment
    managed_by  = "terraform"
  }
}
