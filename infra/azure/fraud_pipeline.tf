resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

# 1. Event Hubs Namespace (Basic Tier) & Ingestion Hub
resource "azurerm_eventhub_namespace" "fraud_ehns" {
  name                = "ehns-fraud-${var.environment}-${random_string.suffix.result}"
  location            = azurerm_resource_group.fraud_rg.location
  resource_group_name = azurerm_resource_group.fraud_rg.name
  sku                 = "Basic"
  capacity            = 1
}

resource "azurerm_eventhub" "transactions_stream" {
  name                = "evh-transactions-${var.environment}"
  namespace_name      = azurerm_eventhub_namespace.fraud_ehns.name
  resource_group_name = azurerm_resource_group.fraud_rg.name
  partition_count     = 2
  message_retention   = 1
}

resource "azurerm_eventhub_namespace_authorization_rule" "fn_listen" {
  name                = "fn-listen-send-rule"
  namespace_name      = azurerm_eventhub_namespace.fraud_ehns.name
  resource_group_name = azurerm_resource_group.fraud_rg.name
  listen              = true
  send                = true
  manage              = false
}

# 2. Cosmos DB Account (Serverless Capacity Mode) & Alerts Container
resource "azurerm_cosmosdb_account" "fraud_cosmos" {
  name                = "cosmos-fraud-${var.environment}-${random_string.suffix.result}"
  location            = azurerm_resource_group.fraud_rg.location
  resource_group_name = azurerm_resource_group.fraud_rg.name
  offer_type          = "Standard"
  kind                = "GlobalDocumentDB"

  capabilities {
    name = "EnableServerless"
  }

  consistency_policy {
    consistency_level = "Session"
  }

  geo_location {
    location          = azurerm_resource_group.fraud_rg.location
    failover_priority = 0
  }
}

resource "azurerm_cosmosdb_sql_database" "fraud_db" {
  name                = "frauddb"
  resource_group_name = azurerm_resource_group.fraud_rg.name
  account_name        = azurerm_cosmosdb_account.fraud_cosmos.name
}

resource "azurerm_cosmosdb_sql_container" "fraud_alerts" {
  name                = "fraud_alerts"
  resource_group_name = azurerm_resource_group.fraud_rg.name
  account_name        = azurerm_cosmosdb_account.fraud_cosmos.name
  database_name       = azurerm_cosmosdb_sql_database.fraud_db.name
  partition_key_paths = ["/account_id"]
}

# 3. Package Python Function Code & Provision Consumption Plan (Y1) Function App
data "archive_file" "azure_scorer_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../../src/azure_scorer"
  output_path = "${path.module}/azure_scorer.zip"
}

resource "azurerm_storage_account" "fn_storage" {
  name                     = "stfnfraud${var.environment}${random_string.suffix.result}"
  resource_group_name      = azurerm_resource_group.fraud_rg.name
  location                 = azurerm_resource_group.fraud_rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

resource "azurerm_service_plan" "fn_plan" {
  name                = "asp-fraud-${var.environment}"
  resource_group_name = azurerm_resource_group.fraud_rg.name
  location            = "eastus"
  os_type             = "Linux"
  sku_name            = "Y1"
}

resource "azurerm_application_insights" "fn_insights" {
  name                = "appi-fraud-${var.environment}"
  location            = azurerm_resource_group.fraud_rg.location
  resource_group_name = azurerm_resource_group.fraud_rg.name
  application_type    = "other"
}

resource "azurerm_linux_function_app" "anomaly_scorer" {
  name                       = "func-fraud-scorer-${var.environment}-${random_string.suffix.result}"
  resource_group_name        = azurerm_resource_group.fraud_rg.name
  location                   = "eastus"
  storage_account_name       = azurerm_storage_account.fn_storage.name
  storage_account_access_key = azurerm_storage_account.fn_storage.primary_access_key
  service_plan_id            = azurerm_service_plan.fn_plan.id
  zip_deploy_file            = data.archive_file.azure_scorer_zip.output_path

  site_config {
    application_insights_connection_string = azurerm_application_insights.fn_insights.connection_string
    application_stack {
      python_version = "3.11"
    }
  }

  app_settings = {
    "FUNCTIONS_WORKER_RUNTIME"       = "python"
    "AzureWebJobsFeatureFlags"       = "EnableWorkerIndexing"
    "SCM_DO_BUILD_DURING_DEPLOYMENT" = "true"
    "ENABLE_ORYX_BUILD"              = "true"
    "EventHubConnectionString"       = azurerm_eventhub_namespace_authorization_rule.fn_listen.primary_connection_string
    "CosmosDbConnectionString"       = azurerm_cosmosdb_account.fraud_cosmos.primary_sql_connection_string
  }
}

# 4. Azure Monitor Metric Alert on Function Execution Failures
resource "azurerm_monitor_metric_alert" "fn_errors" {
  name                = "alert-fraud-scorer-errors-${var.environment}"
  resource_group_name = azurerm_resource_group.fraud_rg.name
  scopes              = [azurerm_linux_function_app.anomaly_scorer.id]
  description         = "Alert when Azure Function invocation failures exceed 0"
  severity            = 2
  frequency           = "PT5M"
  window_size         = "PT5M"

  criteria {
    metric_namespace = "Microsoft.Web/sites"
    metric_name      = "Http5xx"
    aggregation      = "Total"
    operator         = "GreaterThan"
    threshold        = 0
  }
}

output "azure_function_app_name" {
  value = azurerm_linux_function_app.anomaly_scorer.name
}

output "azure_eventhub_namespace" {
  value = azurerm_eventhub_namespace.fraud_ehns.name
}

output "azure_cosmos_account" {
  value = azurerm_cosmosdb_account.fraud_cosmos.name
}