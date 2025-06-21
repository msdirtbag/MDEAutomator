//MDEAutomator
//Version: 1.6.2
//Author: msdirtbag

//Scope
targetScope = 'resourceGroup'

//Variables
var environmentid = uniqueString(tenant().tenantId, subscription().id, env)
var location = resourceGroup().location
var vnetspace = '10.0.0.0/22'
var mainsnetspace = '10.0.0.0/24'
var funcsnetspace = '10.0.1.0/24'
param zones array = [
  'agentsvc.azure-automation.net'
  'monitor.azure.com'
  'ods.opinsights.azure.com'
  'oms.opinsights.azure.com'
]

//Parameters

@description('Chose a variable for the environment. Example: dev, test, soc')
@minLength(1)
@maxLength(10)
param env string = 'dev'

@description('Set to true to use an existing Log Analytics Workspace, false to create a new one')
param useExistingWorkspace bool = false

@description('Resource ID of existing Log Analytics Workspace (required if useExistingWorkspace is true)')
param existingWorkspaceResourceId string = ''


//Resources

//This deploys the Virtual Network Resource Type and Subnet Resource Type.
resource virtualnetwork 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: 'vnet-mdeauto-${environmentid}'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetspace
      ]
    }
    subnets: [
      {
        name: 'main'
        properties: {
          addressPrefix: mainsnetspace
          privateEndpointNetworkPolicies: 'Disabled'
          privateLinkServiceNetworkPolicies: 'Disabled'
          defaultOutboundAccess: false
          networkSecurityGroup: {
            id: mainnsg.id
          }
          serviceEndpoints: [
            {
              service: 'Microsoft.AzureActiveDirectory'
            }
          ]
        }
      }
      {
        name: 'func'
        properties: {
          addressPrefix: funcsnetspace
          privateEndpointNetworkPolicies: 'Disabled'
          privateLinkServiceNetworkPolicies: 'Disabled'
          defaultOutboundAccess: false
          networkSecurityGroup: {
            id: funcnsg.id
          }
          serviceEndpoints: [
            {
              service: 'Microsoft.AzureActiveDirectory'
            }
            {
              service: 'Microsoft.CognitiveServices'
            }
          ]
          delegations: [
            {
              name: 'Microsoft.Web/serverFarms'
              properties: {
                serviceName: 'Microsoft.Web/serverFarms'
              }
            }
          ]
        }
      }
    ]
  }
}

//Diagnostic settings for Virtual Network
resource virtualnetworkdiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'Monitor'
  scope: virtualnetwork
  properties: {
    metrics: [
      {
        category: 'allMetrics'
        enabled: true
      }
    ]
    workspaceId: useExistingWorkspace ? existingWorkspaceResourceId : logAnalyticsWorkspace.id
  }
}

//This deploys the Azure Private DNS Zone for the Virtual Network.
resource dnsblob 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.blob.${environment().suffixes.storage}'
  location: 'global'
}

//This deploys the Azure Private DNS Zone for the Virtual Network.
resource dnsfile 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.file.${environment().suffixes.storage}'
  location: 'global'
}

//This deploys the Azure Private DNS Zone for the Virtual Network.
resource dnsqueue 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.queue.${environment().suffixes.storage}'
  location: 'global'
}

//This deploys the Azure Private DNS Zone for the Virtual Network.
resource dnstable 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.table.${environment().suffixes.storage}'
  location: 'global'
}

//This deploys the Azure Private DNS Zone for the Virtual Network.
resource dnswebsites 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.azurewebsites.net'
  location: 'global'
}

//This deploys the Azure Private DNS Zone for the Virtual Network.
resource dnscognitive 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.openai.azure.com'
  location: 'global'
}

//This links the Azure Private DNS Zone to the Virtual Network.
resource dnsblobvnetlink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: dnsblob
  name: virtualnetwork.name
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: virtualnetwork.id
    }
  }
}

//This links the Azure Private DNS Zone to the Virtual Network.
resource dnsfilevnetlink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: dnsfile
  name: virtualnetwork.name
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: virtualnetwork.id
    }
  }
}

//This links the Azure Private DNS Zone to the Virtual Network.
resource dnsqueuevnetlink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: dnsqueue
  name: virtualnetwork.name
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: virtualnetwork.id
    }
  }
}

//This links the Azure Private DNS Zone to the Virtual Network.
resource dnstablevnetlink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: dnstable
  name: virtualnetwork.name
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: virtualnetwork.id
    }
  }
}

//This links the Azure Private DNS Zone to the Virtual Network.
resource dnswebsitesvnetlink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: dnswebsites
  name: virtualnetwork.name
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: virtualnetwork.id
    }
  }
}

//This links the Azure Private DNS Zone to the Virtual Network.
resource dnscognitivevnetlink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: dnscognitive
  name: virtualnetwork.name
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: virtualnetwork.id
    }
  }
}

//This deploys the Network Security Groups for Main.
resource mainnsg 'Microsoft.Network/networkSecurityGroups@2023-04-01' = {
  name: 'nsg-mdeauto-main-${environmentid}'
  location: location
  properties: {
    securityRules: [
      {
        name: 'Allow_VNET_Inbound'
        properties: {
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: 'VirtualNetwork'
          access: 'Allow'
          priority: 800
          direction: 'Inbound'
        }
      }
      {
        name: 'Allow_VNET_Outbound'
        properties: {
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: 'VirtualNetwork'
          access: 'Allow'
          priority: 800
          direction: 'Outbound'
        }
      }
      {
        name: 'Allow_AzureCloud_Outbound'
        properties: {
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: 'AzureCloud'
          access: 'Allow'
          priority: 900
          direction: 'Outbound'
        }
      }
    ]
  }
}

//Diagnostic settings
resource mainnsgdiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'Monitor-mainnsg'
  scope: mainnsg
  properties: {
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    workspaceId: useExistingWorkspace ? existingWorkspaceResourceId : logAnalyticsWorkspace.id
  }
}

//This deploys the Network Security Groups for Main.
resource funcnsg 'Microsoft.Network/networkSecurityGroups@2023-04-01' = {
  name: 'nsg-mdeauto-func-${environmentid}'
  location: location
  properties: {
    securityRules: [
      {
        name: 'Allow_VNET_Inbound'
        properties: {
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: 'VirtualNetwork'
          access: 'Allow'
          priority: 800
          direction: 'Inbound'
        }
      }
      {
        name: 'Allow_VNET_Outbound'
        properties: {
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: 'VirtualNetwork'
          access: 'Allow'
          priority: 800
          direction: 'Outbound'
        }
      }
      {
        name: 'Allow_AzureCloud_Outbound'
        properties: {
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: 'AzureCloud'
          access: 'Allow'
          priority: 900
          direction: 'Outbound'
        }
      }
    ]
  }
}

//Diagnostic settings
resource funcnsgdiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'Monitor-funcnsg'
  scope: funcnsg
  properties: {
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    workspaceId: useExistingWorkspace ? existingWorkspaceResourceId : logAnalyticsWorkspace.id
  }
}

// User Managed Identity
resource managedidentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: 'umi-mdeautomator-${environmentid}'
  location: location
}

// Cognitive Services Account for OpenAI
resource aiaccount 'Microsoft.CognitiveServices/accounts@2023-05-01' = {
  name: 'oai-mdeautomator-${environmentid}'
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${managedidentity.id}': {}
    }
  }
  sku: {
    name: 'S0'
  }
  kind: 'OpenAI'
  properties: {
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      defaultAction: 'Deny'
      virtualNetworkRules: [
        {
          id: virtualnetwork.properties.subnets[1].id
        }
      ]
      bypass: 'AzureServices'
    }
    disableLocalAuth: false
    customSubDomainName: 'mdeautomator-${environmentid}'
  }
}

// Diagnostic settings for Cognitive Services Account
resource aiaccountdiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'Monitor-AIAccount'
  scope: aiaccount
  properties: {
    logs: [
      {
        categoryGroup: 'AllLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
    workspaceId: useExistingWorkspace ? existingWorkspaceResourceId : logAnalyticsWorkspace.id
  }
}

// Cognitive Services Deployment for OpenAI Model
resource model 'Microsoft.CognitiveServices/accounts/deployments@2023-05-01' = {
  name: 'gpt-4-1'
  parent: aiaccount
  sku: {
    name: 'GlobalStandard'
    capacity: 10
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: 'gpt-4.1'
      version: '2025-04-14'
    }
  }
}

//This deploys the Cognitive Services Private Endpoint.
resource aiaccountpe 'Microsoft.Network/privateEndpoints@2023-04-01' = {
  name: 'pe-${environmentid}aiaccount'
  location: location
  properties: {
    subnet: {
      id: virtualnetwork.properties.subnets[0].id
    }
    privateLinkServiceConnections: [
      {
        name: 'psc-${environmentid}aiaccount'
        properties: {
          privateLinkServiceId: aiaccount.id
          groupIds: [
            'account'
          ]
        }
      }
    ]
  }
}

// Create Private DNS Zone Group.
resource aipegroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-04-01' = {
  name: aiaccount.name
  parent: aiaccountpe
  properties: {
    privateDnsZoneConfigs: [
      {
        name: aiaccount.name
        properties: {
          privateDnsZoneId: dnscognitive.id
        }
      }
    ]
  }
}

// Reader Role Assignment
resource readerroleassign 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(environmentid, 'acdd72a7-3385-48ef-bd42-f606fba81ae7', subscription().id)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'acdd72a7-3385-48ef-bd42-f606fba81ae7')
    principalId: managedidentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// Storage Blob Data Owner Role Assignment
resource blobroleassign 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(environmentid, 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b', subscription().id)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b')
    principalId: managedidentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// Storage Table Data Contributor Role Assignment
resource tableroleassign 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(environmentid, '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3', subscription().id)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3')
    principalId: managedidentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// Storage Queue Data Contributor Role Assignment
resource queueroleassign 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(environmentid, '974c5e8b-45b9-4653-ba55-5f855dd0fb88', subscription().id)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '974c5e8b-45b9-4653-ba55-5f855dd0fb88')
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

// Diagnostic settings for Storage Account
resource storage01diag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'Monitor-Storage'
  scope: storage01
  properties: {
    metrics: [
      {
        category: 'Transaction'
        enabled: true
      }
    ]
    workspaceId: useExistingWorkspace ? existingWorkspaceResourceId : logAnalyticsWorkspace.id
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

// Hunt Query Blob Container
resource huntquerycontainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2024-01-01' = {
  name: 'huntquery'
  parent: blobservice
  properties: {
    publicAccess: 'None'
  }
}

// Log Analytics Workspace (conditional creation)
resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = if (!useExistingWorkspace) {
  name: 'log-mdeautomator-${environmentid}'
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${managedidentity.id}': {}
    }
  }
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    publicNetworkAccessForIngestion: 'Disabled'
    publicNetworkAccessForQuery: 'Enabled'
    retentionInDays: 30
  }
}

resource laamplslink 'Microsoft.Insights/privateLinkScopes/scopedResources@2021-07-01-preview' = {
  name: 'laampls-${environmentid}'
  parent: amplsscope
  properties: {
    linkedResourceId: useExistingWorkspace ? existingWorkspaceResourceId : logAnalyticsWorkspace.id
  }
}

//This deploys the Function Storage Blob Private Endpoint.
resource funcblob01pe 'Microsoft.Network/privateEndpoints@2023-04-01' = {
  name: 'pe-${environmentid}funcst01blob'
  location: location
  properties: {
    subnet: {
      id: virtualnetwork.properties.subnets[0].id
    }
    privateLinkServiceConnections: [
      {
        name: 'psc-${environmentid}funcst01blob'
        properties: {
          privateLinkServiceId: storage01.id
          groupIds: [
            'blob'
          ]
        }
      }
    ]
  }
}

// Create Private DNS Zone Group.
resource funcblob01pegroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-04-01' = {
  name: storage01.name
  parent: funcblob01pe
  properties: {
    privateDnsZoneConfigs: [
      {
        name: storage01.name
        properties: {
          privateDnsZoneId: dnsblob.id
        }
      }
    ]
  }
}

//This deploys the Function Storage File Private Endpoint.
resource funcfile01pe 'Microsoft.Network/privateEndpoints@2023-04-01' = {
  name: 'pe-${environmentid}funcst01file'
  location: location
  properties: {
    subnet: {
      id: virtualnetwork.properties.subnets[0].id
    }
    privateLinkServiceConnections: [
      {
        name: 'psc-func01file-${environmentid}'
        properties: {
          privateLinkServiceId: storage01.id
          groupIds: [
            'file'
          ]
        }
      }
    ]
  }
}

// Create Private DNS Zone Group.
resource funcfile01pegroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-04-01' = {
  name: storage01.name
  parent: funcfile01pe
  properties: {
    privateDnsZoneConfigs: [
      {
        name: storage01.name
        properties: {
          privateDnsZoneId: dnsfile.id
        }
      }
    ]
  }
}

//This deploys the Function Storage Queue Private Endpoint.
resource funcqueue01pe 'Microsoft.Network/privateEndpoints@2023-04-01' = {
  name: 'pe-${environmentid}funcst01queue'
  location: location
  properties: {
    subnet: {
      id: virtualnetwork.properties.subnets[0].id
    }
    privateLinkServiceConnections: [
      {
        name: 'psc-${environmentid}funcst01queue'
        properties: {
          privateLinkServiceId: storage01.id
          groupIds: [
            'queue'
          ]
        }
      }
    ]
  }
}

// Create Private DNS Zone Group.
resource funcqueue01pegroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-04-01' = {
  name: storage01.name
  parent: funcqueue01pe
  properties: {
    privateDnsZoneConfigs: [
      {
        name: storage01.name
        properties: {
          privateDnsZoneId: dnsqueue.id
        }
      }
    ]
  }
}

//This deploys the Function Storage Table Private Endpoint.
resource functable01pe 'Microsoft.Network/privateEndpoints@2023-04-01' = {
  name: 'pe-${environmentid}funcst01table'
  location: location
  properties: {    subnet: {
      id: virtualnetwork.properties.subnets[0].id
    }
    privateLinkServiceConnections: [
      {
        name: 'psc-${environmentid}funcst01table'
        properties: {
          privateLinkServiceId: storage01.id
          groupIds: [
            'table'
          ]
        }
      }
    ]
  }
}

// Create Private DNS Zone Group.
resource functable01pegroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-04-01' = {
  name: storage01.name
  parent: functable01pe
  properties: {
    privateDnsZoneConfigs: [
      {
        name: storage01.name
        properties: {
          privateDnsZoneId: dnstable.id
        }
      }
    ]
  }
}

// Application Insights
resource appinsights01 'Microsoft.Insights/components@2020-02-02' = {
  name: 'appi-mdeauto${environmentid}'
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    RetentionInDays: 30
    DisableLocalAuth: false
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
    WorkspaceResourceId: useExistingWorkspace ? existingWorkspaceResourceId : logAnalyticsWorkspace.id
  }
}

//Diagnostic settings for Application Insights
resource appinsights01diag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'Monitor-Appinsights'
  scope: appinsights01
  properties: {
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'allMetrics'
        enabled: true
      }
    ]
    workspaceId: useExistingWorkspace ? existingWorkspaceResourceId : logAnalyticsWorkspace.id
  }
}

resource aiamplslink 'Microsoft.Insights/privateLinkScopes/scopedResources@2021-07-01-preview' = {
  name: 'aiampls-${environmentid}'
  parent: amplsscope
  properties: {
    linkedResourceId: appinsights01.id
  }
}

// App Service Plan
resource appservicefunc 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: 'asp-mdeautomator-func-${environmentid}'
  location: location
  properties: {
    reserved: false
    elasticScaleEnabled: true
    maximumElasticWorkerCount: 5
  }
  sku: {
    tier: 'ElasticPremium'
    name: 'EP1'    
  }
}

//Diagnostic settings for App Service Plan.
resource appservicediag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'Monitor-AppServicePlanFunc'
  scope: appservicefunc
  properties: {
    metrics: [
      {
        category: 'allMetrics'
        enabled: true
      }
    ]
    workspaceId: useExistingWorkspace ? existingWorkspaceResourceId : logAnalyticsWorkspace.id
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
    serverFarmId: appservicefunc.id
    virtualNetworkSubnetId: virtualnetwork.properties.subnets[1].id
    publicNetworkAccess: 'Disabled'
    httpsOnly: true
    siteConfig: {
      vnetRouteAllEnabled: true
      autoHealEnabled: true
      detailedErrorLoggingEnabled: true
      httpLoggingEnabled: true
      cors: {
        allowedOrigins: [
          'https://portal.azure.com'
          'https://preview.portal.azure.com'
          'https://${appservice.properties.defaultHostName}'
        ]
        supportCredentials: true
      }
      preWarmedInstanceCount: 5
      remoteDebuggingEnabled: false
      requestTracingEnabled: true
      scmMinTlsVersion: '1.2'
      minTlsVersion: '1.2'
      http20Enabled: true
      functionAppScaleLimit: 10
      functionsRuntimeScaleMonitoringEnabled: true
      appSettings: [        {
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
            value: 'DefaultEndpointsProtocol=https;AccountName=${storage01.name};AccountKey=${storage01.listKeys().keys[0].value};EndpointSuffix=${environment().suffixes.storage}'
        }
        {
            name: 'AzureWebJobsStorage__accountname'
            value: storage01.name
        }
        {
            name: 'AzureWebJobsStorage__blobServiceUri'
            value: 'https://${storage01.name}.blob.${environment().suffixes.storage}/'
        }
        {
            name: 'AzureWebJobsStorage__queueServiceUri'
            value: 'https://${storage01.name}.queue.${environment().suffixes.storage}/'
        }
        {
            name: 'AzureWebJobsStorage__tableServiceUri'
            value: 'https://${storage01.name}.table.${environment().suffixes.storage}/'
        }
        {
            name: 'AzureWebJobsStorage__fileServiceUri'
            value: 'https://${storage01.name}.file.${environment().suffixes.storage}/'
        }
        {
            name: 'WEBSITE_CONTENTAZUREFILECONNECTIONSTRING'
            value: 'DefaultEndpointsProtocol=https;AccountName=${storage01.name};AccountKey=${storage01.listKeys().keys[0].value}'
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
            name: 'AZURE_AI_ENDPOINT'
            value: aiaccount.properties.endpoint
        }
        {
            name: 'AZURE_AI_KEY'
            value: aiaccount.listKeys().key1
        }
        {
            name: 'AZURE_AI_MODEL'
            value: 'gpt-4-1'
        }
        {
            name: 'SPNID'
            value: ''
        }
      ]
      use32BitWorkerProcess: false
      ftpsState: 'Disabled'
      powerShellVersion: '7.4'
    }
  }
}

//Diagnostic settings for Function
resource functiondiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'Monitor-Function'
  scope: function01
  properties: {
    logs: [
      {
        category: 'FunctionAppLogs'
        enabled: true
      }
      {
        category: 'AppServiceAuthenticationLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'allMetrics'
        enabled: true
      }
    ]
    workspaceId: useExistingWorkspace ? existingWorkspaceResourceId : logAnalyticsWorkspace.id
  }
}

//This deploys the Function Private Endpoint.
resource function01pe 'Microsoft.Network/privateEndpoints@2023-04-01' = {
  name: 'pe-func01-${environmentid}'
  location: location
  properties: {
    subnet: {
      id: virtualnetwork.properties.subnets[0].id
    }
    privateLinkServiceConnections: [
      {
        name: 'psc-func01-${environmentid}'
        properties: {
          privateLinkServiceId: function01.id
          groupIds: [
            'sites'
          ]
        }
      }
    ]
  }
}

// Create Private DNS Zone Group.
resource func01zonegroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-04-01' = {
  name: function01.name
  parent: function01pe
  properties: {
    privateDnsZoneConfigs: [
      {
        name: function01.name
        properties: {
          privateDnsZoneId: dnswebsites.id
        }
      }
    ]
  }
}

//App Service Plan
resource appserviceplan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: 'asp-mdeautomator-web-${environmentid}'
  location: location
  properties: {
    reserved: true
  }
  sku: {
    tier: 'Basic'
    name: 'B1'    
  }
  kind: 'linux'
}

//Diagnostic settings for App Service Plan.
resource appserviceplandiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'Monitor-AppServicePlan'
  scope: appserviceplan
  properties: {
    metrics: [
      {
        category: 'allMetrics'
        enabled: true
      }
    ]
    workspaceId: useExistingWorkspace ? existingWorkspaceResourceId : logAnalyticsWorkspace.id
  }
}

//This deploys the Azure App Service.
resource appservice 'Microsoft.Web/sites@2022-09-01' = {
  name: 'ase-mdeautomator-${environmentid}'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${managedidentity.id}': {}
    }
  }
  location: location
  kind: 'container'
  properties: {
    serverFarmId: appserviceplan.id
    publicNetworkAccess: 'Enabled'
    virtualNetworkSubnetId: virtualnetwork.properties.subnets[1].id
    httpsOnly: true
    siteConfig: {
      linuxFxVersion: 'DOCKER|msdirtbag/mdeautomator:latest'
      numberOfWorkers: 1
      requestTracingEnabled: false
      remoteDebuggingEnabled: false
      httpLoggingEnabled: true
      logsDirectorySizeLimit: 35
      detailedErrorLoggingEnabled: true
      webSocketsEnabled: true
      alwaysOn: true
      autoHealEnabled: true
      ipSecurityRestrictions: [
        {
          ipAddress: 'Any'
          action: 'Allow'
          priority: 2147483647
          name: 'Allow all'
          description: 'Allow all access'
        }
      ]
      scmIpSecurityRestrictions: [
        {
          ipAddress: 'Any'
          action: 'Deny'
          priority: 2147483647
          name: 'Block all'
          description: 'Block all access'
        }
      ]
      scmIpSecurityRestrictionsUseMain: false
      http20Enabled: false
      minTlsVersion: '1.2'
      scmMinTlsVersion: '1.2'
      ftpsState: 'Disabled'
      minimumElasticInstanceCount: 1
    }
  }
}

//Diagnostic settings for App Service.
resource appservicediagweb 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'Monitor-AppService'
  scope: appservice
  properties: {
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'allMetrics'
        enabled: true
      }
    ]
    workspaceId: useExistingWorkspace ? existingWorkspaceResourceId : logAnalyticsWorkspace.id
  }
}

// This configures the app settings for the Azure Function.
resource appsettings 'Microsoft.Web/sites/config@2022-09-01' = {
  name: 'appsettings'
  kind: 'calappsettings'
  parent: appservice
  properties: {
    FUNCKEY: listKeys(resourceId('Microsoft.Web/sites/host', function01.name, 'default'), '2022-03-01').functionKeys.default
    FUNCURL: function01.properties.defaultHostName
  }
}

//This deploys the Azure Monitor Private Link Scope.
resource amplsscope 'microsoft.insights/privateLinkScopes@2021-07-01-preview' = {
  name: 'ampls-mdeautomator-${environmentid}'
  location: 'global'
  properties: {
    accessModeSettings: {
      ingestionAccessMode: 'PrivateOnly'
      queryAccessMode: 'Open'
    }
  }
}

//This deploys the Azure Monitor Private Endpoint.
resource amplsscopeprivatendpoint 'Microsoft.Network/privateEndpoints@2023-04-01' = {
  name: 'pe-ampls'
  location: location
  properties: {
    subnet: {
      id: virtualnetwork.properties.subnets[0].id
    }
    privateLinkServiceConnections: [
      {
        name: 'psc-ampls'
        properties: {
          privateLinkServiceId: amplsscope.id
          groupIds: [
            'azuremonitor'
          ]
        }
      }
    ]
  }
  dependsOn: [
    privatednszoneforampls
    privatednszonelink
  ]
}

// Create Private DNS Zone for "pe-ampls"
resource privatednszoneforampls 'Microsoft.Network/privateDnsZones@2024-06-01' = [for zone in zones: {
  name: 'privatelink.${zone}'
  location: 'global'
  properties: {
  }
}]

//This deploys the DNS Zone Link.
resource privatednszonelink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [for (zone,i) in zones: { 
  parent: privatednszoneforampls[i]
  name: '${zone}-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: virtualnetwork.id
    }
  }
}]

// Create Private DNS Zone Group.
resource pednsgroupforampls 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-06-01' = {
  parent: amplsscopeprivatendpoint
  name: 'pvtendpointdnsgroupforampls'
  properties: {
    privateDnsZoneConfigs: [
      for (zone,i) in zones: {
        name: privatednszoneforampls[i].name
        properties: {
          privateDnsZoneId: privatednszoneforampls[i].id
        }
      }
    ]
  }
}


