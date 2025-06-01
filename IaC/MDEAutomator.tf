terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "4.10.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.7.2"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id = "00000000-0000-0000-0000-000000000000" # Replace with your Azure subscription ID
}

data "azurerm_client_config" "current" {}

variable "env" {
  description = "Chose a variable for the environment. Example: dev, test, soc"
  type        = string
  validation {
    condition     = contains(["dev", "test", "soc"], var.env)
    error_message = "Environment must be one of: dev, test, soc."
  }
}

resource "random_string" "environmentid" {
  length  = 8
  special = false
  upper   = false
  lower   = true
  numeric = true
}

resource "azurerm_resource_group" "rg" {
  name     = "rg-mdeautomator-${var.env}"
  location = "Australia East" # Change as needed
}

resource "azurerm_user_assigned_identity" "umi" {
  name                = "umi-mdeautomator-${random_string.environmentid.result}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_role_assignment" "storage_blob_data_contributor" {
  scope                = azurerm_resource_group.rg.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.umi.principal_id
}

resource "azurerm_role_assignment" "storage_table_data_contributor" {
  scope                = azurerm_resource_group.rg.id
  role_definition_name = "Storage Table Data Contributor"
  principal_id         = azurerm_user_assigned_identity.umi.principal_id
}

resource "azurerm_role_assignment" "monitoring_metrics_publisher" {
  scope                = azurerm_resource_group.rg.id
  role_definition_name = "Monitoring Metrics Publisher"
  principal_id         = azurerm_user_assigned_identity.umi.principal_id
}

resource "azurerm_storage_account" "storage_account" {
  name                     = "stmdeauto${random_string.environmentid.result}"
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.umi.id]
  }
  min_tls_version                   = "TLS1_2"
  public_network_access_enabled     = true
  allow_nested_items_to_be_public   = false
  https_traffic_only_enabled        = true
  infrastructure_encryption_enabled = true
}

resource "azurerm_storage_container" "packages" {
  name                  = "packages"
  storage_account_id    = azurerm_storage_account.storage_account.id
  container_access_type = "private"
}

resource "azurerm_storage_container" "files" {
  name                  = "files"
  storage_account_id    = azurerm_storage_account.storage_account.id
  container_access_type = "private"
}

resource "azurerm_storage_container" "payloads" {
  name                  = "payloads"
  storage_account_id    = azurerm_storage_account.storage_account.id
  container_access_type = "private"
}

resource "azurerm_storage_container" "output" {
  name                  = "output"
  storage_account_id    = azurerm_storage_account.storage_account.id
  container_access_type = "private"
}

resource "azurerm_storage_container" "detections" {
  name                  = "detections"
  storage_account_id    = azurerm_storage_account.storage_account.id
  container_access_type = "private"
}

resource "azurerm_storage_container" "huntquery" {
  name                  = "huntquery"
  storage_account_id    = azurerm_storage_account.storage_account.id
  container_access_type = "private"
}

resource "azurerm_log_analytics_workspace" "app_insights_workspace" {
  name                = "law-mdeauto-${random_string.environmentid.result}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

resource "azurerm_application_insights" "app_insights" {
  name                = "appi-mdeauto-${random_string.environmentid.result}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  application_type    = "web"
  retention_in_days   = 60
  workspace_id        = azurerm_log_analytics_workspace.app_insights_workspace.id
  depends_on = [ azurerm_log_analytics_workspace.app_insights_workspace ]
}

resource "azurerm_service_plan" "func_service_plan" {
  name                         = "asp-mdeautomator-func-${random_string.environmentid.result}"
  location                     = azurerm_resource_group.rg.location
  resource_group_name          = azurerm_resource_group.rg.name
  os_type                      = "Linux"
  sku_name                     = "EP1"
  maximum_elastic_worker_count = 2
}

resource "azurerm_linux_function_app" "func" {
  name                       = "func-mdeautomator-${random_string.environmentid.result}"
  location                   = azurerm_resource_group.rg.location
  resource_group_name        = azurerm_resource_group.rg.name
  service_plan_id            = azurerm_service_plan.func_service_plan.id
  storage_account_name       = azurerm_storage_account.storage_account.name
  storage_account_access_key = azurerm_storage_account.storage_account.primary_access_key
  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.umi.id]
  }
  app_settings = {
    FUNCTIONS_EXTENSION_VERSION                = "~4"
    APPLICATIONINSIGHTS_CONNECTION_STRING      = azurerm_application_insights.app_insights.connection_string
    APPLICATIONINSIGHTS_AUTHENTICATION_STRING  = "Authorization=AAD;ClientId=${azurerm_user_assigned_identity.umi.client_id}"
    ApplicationInsightsAgent_EXTENSION_VERSION = "~3"
    APPLICATIONINSIGHTS_ENABLE_AGENT           = "true"
    FUNCTIONS_WORKER_RUNTIME                   = "powershell"
    AzureWebJobsStorage                        = azurerm_storage_account.storage_account.primary_connection_string
    WEBSITE_CONTENTAZUREFILECONNECTIONSTRING   = azurerm_storage_account.storage_account.primary_connection_string
    WEBSITE_RUN_FROM_PACKAGE                   = "https://github.com/msdirtbag/MDEAutomator/raw/refs/heads/main/payloads/MDEAutomator.zip?isAsync=true"
    FUNCTIONS_WORKER_PROCESS_COUNT             = "10"
    PSWorkerInProcConcurrencyUpperBound        = "1000"
    AZURE_CLIENT_ID                            = azurerm_user_assigned_identity.umi.client_id
    SUBSCRIPTION_ID                            = data.azurerm_client_config.current.subscription_id
    STORAGE_ACCOUNT                            = azurerm_storage_account.storage_account.id
    SPNID                                      = ""
  }
  site_config {
    always_on                 = true
    ftps_state                = "Disabled"
    minimum_tls_version       = "1.2"
    http2_enabled             = true
    pre_warmed_instance_count = 10
    application_stack {
      powershell_core_version = "7.4"
    }
  }
  depends_on = [ azurerm_service_plan.func_service_plan, azurerm_application_insights.app_insights ]
  lifecycle {
    ignore_changes = [
      app_settings["SPNID"]
    ]
  }
}

resource "azurerm_service_plan" "webapp_service_plan" {
  name                = "asp-mdeautomator-web-${random_string.environmentid.result}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  os_type             = "Linux"
  sku_name            = "B1"
}

resource "azurerm_linux_web_app" "webapp" {
  name                = "webapp-mdeautomator-${random_string.environmentid.result}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  service_plan_id     = azurerm_service_plan.webapp_service_plan.id
  https_only          = true

  site_config {
    always_on                   = true
    ftps_state                  = "Disabled"
    http2_enabled               = false
    minimum_tls_version         = "1.2"
    scm_minimum_tls_version     = "1.2"
    websockets_enabled          = true
    remote_debugging_enabled    = false
    worker_count                = 1
    scm_use_main_ip_restriction = false

    ip_restriction {
      ip_address  = "0.0.0.0/0"
      action      = "Allow"
      priority    = 2147483647
      name        = "Allow all"
      description = "Allow all access"
    }

    scm_ip_restriction {
      ip_address  = "0.0.0.0/0"
      action      = "Deny"
      priority    = 2147483647
      name        = "Block all"
      description = "Block all access"
    }

    # Docker container
    application_stack {
      docker_image_name = "msdirtbag/mdeautomator:latest"
    }
  }

  logs {
    failed_request_tracing  = true
    detailed_error_messages = true
    http_logs {
      azure_blob_storage {
        sas_url           = azurerm_storage_account.storage_account.primary_blob_connection_string
        retention_in_days = 7
      }
    }
  }

  app_settings = {
    WEBSITES_ENABLE_APP_SERVICE_STORAGE = "false" # typical for Docker containers
  }
  depends_on = [ azurerm_service_plan.webapp_service_plan, azurerm_application_insights.app_insights ]
}

output "function_app_url" {
  value = azurerm_linux_function_app.func.default_hostname
}

output "web_app_url" {
  value = azurerm_linux_web_app.webapp.default_hostname
}