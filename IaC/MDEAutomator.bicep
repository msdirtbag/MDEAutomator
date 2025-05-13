//MDEAutomator
//Version: 1.5.5
//Author: msdirtbag

//Scope
targetScope = 'resourceGroup'

//Variables
var environmentid = uniqueString(tenant().tenantId, subscription().id, env)
var location = resourceGroup().location

//Parameters

@description('Chose a variable for the environment. Example: dev, test, soc')
param env string

//Resources

// User Managed Identity
resource managedidentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: 'umi-mdeautomator-${environmentid}'
  location: location
}

// Storage Blob Data Contributor Role Assignment
resource blobroleassign 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(environmentid, 'ba92f5b4-2d11-453d-a403-e96b0029c9fe', subscription().id)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
    principalId: managedidentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// Monitoring Metrics Publisher Role Assignment
resource monitorroleassign 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(environmentid, '3913510d-42f4-4e42-8a64-420c390055eb', subscription().id)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '3913510d-42f4-4e42-8a64-420c390055eb')
    principalId: managedidentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// Function Storage Account
resource storage01 'Microsoft.Storage/storageAccounts@2024-01-01' = {
  name: 'stmdeauto${environmentid}'
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${managedidentity.id}': {}
    }
  }
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    encryption: {
      keySource: 'Microsoft.Storage'
      requireInfrastructureEncryption: true
      services: {
        blob: {
          enabled: true
        }
        file: {
          enabled: true
        }
        queue: {
          enabled: true
          keyType: 'Service'
        }
        table: {
          enabled: true
          keyType: 'Service'
        }
      }
    }
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
    publicNetworkAccess: 'Enabled'
    minimumTlsVersion: 'TLS1_2'
  }
}

// Blob Service
resource blobservice 'Microsoft.Storage/storageAccounts/blobServices@2024-01-01' = {
  name: 'default'
  parent: storage01
}

// Packages Blob Container
resource packagescontainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2024-01-01' = {
  name: 'packages'
  parent: blobservice
  properties: {
    publicAccess: 'None'
  }
}

// Files Blob Container
resource filescontainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2024-01-01' = {
  name: 'files'
  parent: blobservice
  properties: {
    publicAccess: 'None'
  }
}

// Payloads Blob Container
resource payloadscontainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2024-01-01' = {
  name: 'payloads'
  parent: blobservice
  properties: {
    publicAccess: 'None'
  }
}

// Output Blob Container
resource outputcontainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2024-01-01' = {
  name: 'output'
  parent: blobservice
  properties: {
    publicAccess: 'None'
  }
}

// Detections Blob Container
resource detectionscontainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2024-01-01' = {
  name: 'detections'
  parent: blobservice
  properties: {
    publicAccess: 'None'
  }
}

// Application Insights
resource appinsights01 'Microsoft.Insights/components@2020-02-02' = {
  name: 'appi-mdeauto${environmentid}'
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    RetentionInDays: 60
    DisableLocalAuth: true
  }
}

// App Service Plan
resource appservice 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: 'asp-mdeautomator-${environmentid}'
  location: location
  properties: {
    reserved: false
    elasticScaleEnabled: true
    maximumElasticWorkerCount: 2
  }
  sku: {
    tier: 'ElasticPremium'
    name: 'EP1'    
  }
}

// Azure Function
resource function01 'Microsoft.Web/sites@2023-12-01' = {
  name: 'funcmdeauto${environmentid}'
  kind: 'functionapp'
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${managedidentity.id}': {}
    }
  }
  properties: {
    serverFarmId: appservice.id
    publicNetworkAccess: 'Enabled'
    httpsOnly: true
    siteConfig: {
      autoHealEnabled: true
      detailedErrorLoggingEnabled: true
      httpLoggingEnabled: true
      cors: {
        allowedOrigins: [
          'https://portal.azure.com'
          'https://preview.portal.azure.com'
        ]
        supportCredentials: true
      }
      preWarmedInstanceCount: 10
      remoteDebuggingEnabled: false
      requestTracingEnabled: true
      scmMinTlsVersion: '1.2'
      http20Enabled: true
      functionAppScaleLimit: 100
      functionsRuntimeScaleMonitoringEnabled: true
      appSettings: [
        {
            name: 'FUNCTIONS_EXTENSION_VERSION'
            value: '~4'
        }
        {
            name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
            value: appinsights01.properties.ConnectionString
        }
        {
            name: 'APPLICATIONINSIGHTS_AUTHENTICATION_STRING'
            value: 'Authorization=AAD;ClientId=${managedidentity.properties.clientId}'
        }
        {
            name: 'ApplicationInsightsAgent_EXTENSION_VERSION'
            value: '~3'
        }
        {
            name: 'APPLICATIONINSIGHTS_ENABLE_AGENT'
            value: 'true'
        }
        {
            name: 'FUNCTIONS_WORKER_RUNTIME'
            value: 'powershell'
        }
        {
            name: 'AzureWebJobsStorage'
            value: 'DefaultEndpointsProtocol=https;AccountName=${storage01.name};AccountKey=${listKeys(storage01.id, storage01.apiVersion).keys[0].value}'
        }
        {
            name: 'WEBSITE_CONTENTAZUREFILECONNECTIONSTRING'
            value: 'DefaultEndpointsProtocol=https;AccountName=${storage01.name};AccountKey=${listKeys(storage01.id, storage01.apiVersion).keys[0].value}'
        }
        {
            name: 'WEBSITE_RUN_FROM_PACKAGE'
            value: 'https://github.com/msdirtbag/MDEAutomator/raw/refs/heads/main/payloads/MDEAutomator.zip?isAsync=true'
        }
        {
            name: 'FUNCTIONS_WORKER_PROCESS_COUNT'
            value: '10'
        }
        {
            name: 'PSWorkerInProcConcurrencyUpperBound'
            value: '1000'
        }
        {
            name: 'AZURE_CLIENT_ID'
            value: managedidentity.properties.clientId
        }
        {
            name: 'SUBSCRIPTION_ID'
            value: subscription().subscriptionId
        }
        {
            name: 'STORAGE_ACCOUNT'
            value: storage01.name
        }
        {
            name: 'SPNID'
            value: ''
        }
      ]
      use32BitWorkerProcess: false
      ftpsState: 'Disabled'
      powerShellVersion: '7.4'
      netFrameworkVersion: 'v8.0'
    }
  }
}
