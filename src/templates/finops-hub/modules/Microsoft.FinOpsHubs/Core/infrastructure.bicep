// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

import { getHubTags, getPrivateEndpointName, HubProperties } from '../../fx/hub-types.bicep'


//==============================================================================
// Parameters
//==============================================================================

@description('Required. FinOps hub instance properties.')
param hub HubProperties


//==============================================================================
// Variables
//==============================================================================

// Check if using existing network resources
var useExistingVNet = !empty(hub.existingNetwork.virtualNetworkId)

var nsgName = '${hub.routing.networkName}-nsg'

// Workaround https://github.com/Azure/bicep/issues/1853
var finopsHubSubnetName = 'private-endpoint-subnet'
var scriptSubnetName = 'script-subnet'
var dataExplorerSubnetName = 'dataExplorer-subnet'

// Only define subnets when creating a new VNet (not using existing)
var subnets = !hub.options.privateRouting || useExistingVNet ? [] : [
  {
    name: finopsHubSubnetName
    properties: {
      addressPrefix: cidrSubnet(hub.options.networkAddressPrefix, 28, 0)
      networkSecurityGroup: {
        id: nsg.id
      }
      serviceEndpoints: [
        {
          service: 'Microsoft.Storage'
        }
      ]
    }
  }
  {
    name: scriptSubnetName
    properties: {
      addressPrefix: cidrSubnet(hub.options.networkAddressPrefix, 28, 1)
      networkSecurityGroup: {
        id: nsg.id
      }
      delegations: [
        {
          name: 'Microsoft.ContainerInstance/containerGroups'
          properties: {
            serviceName: 'Microsoft.ContainerInstance/containerGroups'
          }
        }
      ]
      serviceEndpoints: [
        {
          service: 'Microsoft.Storage'
        }
      ]
    }
  }
  {
    name: dataExplorerSubnetName
    properties: {
      addressPrefix: cidrSubnet(hub.options.networkAddressPrefix, 27, 1)
      networkSecurityGroup: {
        id: nsg.id
      }
    }
  }
]


//==============================================================================
// Resources
//==============================================================================

//------------------------------------------------------------------------------
// Network
//------------------------------------------------------------------------------

// Create NSG only if private routing is enabled and creating a new VNet
resource nsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = if (hub.options.privateRouting && !useExistingVNet) {
  name: nsgName
  location: hub.location
  tags: getHubTags(hub, 'Microsoft.Storage/networkSecurityGroups')
  properties: {
    securityRules: [
      {
        name: 'AllowVnetInBound'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: 'VirtualNetwork'
        }
      }
      {
        name: 'AllowAzureLoadBalancerInBound'
        properties: {
          priority: 200
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: 'AzureLoadBalancer'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'DenyAllInBound'
        properties: {
          priority: 4096
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'AllowVnetOutBound'
        properties: {
          priority: 100
          direction: 'Outbound'
          access: 'Allow'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: 'VirtualNetwork'
        }
      }
      {
        name: 'AllowInternetOutBound'
        properties: {
          priority: 200
          direction: 'Outbound'
          access: 'Allow'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: 'Internet'
        }
      }
      {
        name: 'DenyAllOutBound'
        properties: {
          priority: 4096
          direction: 'Outbound'
          access: 'Deny'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

// Create VNet only if private routing is enabled and no existing VNet is provided
resource vNet 'Microsoft.Network/virtualNetworks@2023-11-01' = if (hub.options.privateRouting && !useExistingVNet) {
  name: hub.routing.networkName
  location: hub.location
  tags: getHubTags(hub, 'Microsoft.Storage/virtualNetworks')
  properties: {
    addressSpace: {
      addressPrefixes: [hub.options.networkAddressPrefix]
    }
    subnets: subnets
  }

  resource finopsHubSubnet 'subnets' existing = {
    name: finopsHubSubnetName
  }

  resource scriptSubnet 'subnets' existing = {
    name: scriptSubnetName
  }

  resource dataExplorerSubnet 'subnets' existing = {
    name: dataExplorerSubnetName
  }
}

//------------------------------------------------------------------------------
// Storage DNS zones
//------------------------------------------------------------------------------

// Required for the Azure portal and Storage Explorer
// Create new DNS Zone if not using existing
resource blobPrivateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = if (hub.options.privateRouting && empty(hub.existingDnsZones.blob)) {
  name: string(hub.routing.dnsZones.blob.name)
  dependsOn: [
    vNet
  ]
  location: 'global'
  tags: getHubTags(hub, 'Microsoft.Storage/privateDnsZones')
  properties: {}
}

// Link to VNet (only needed for new zones; existing zones should already be linked)
resource blobPrivateDnsZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = if (hub.options.privateRouting && empty(hub.existingDnsZones.blob)) {
  parent: blobPrivateDnsZone
  name: '${replace(blobPrivateDnsZone.name, '.', '-')}-link'
  location: 'global'
  tags: getHubTags(hub, 'Microsoft.Network/privateDnsZones/virtualNetworkLinks')
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: hub.routing.networkId
    }
  }
}

// Required for Power BI
// Create new DNS Zone if not using existing
resource dfsPrivateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = if (hub.options.privateRouting && empty(hub.existingDnsZones.dfs)) {
  name: string(hub.routing.dnsZones.dfs.name)
  dependsOn: [
    vNet
  ]
  location: 'global'
  tags: getHubTags(hub, 'Microsoft.Storage/privateDnsZones')
  properties: {}
}

// Link to VNet (only needed for new zones; existing zones should already be linked)
resource dfsPrivateDnsZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = if (hub.options.privateRouting && empty(hub.existingDnsZones.dfs)) {
  parent: dfsPrivateDnsZone
  name: '${replace(dfsPrivateDnsZone.name, '.', '-')}-link'
  location: 'global'
  tags: getHubTags(hub, 'Microsoft.Network/privateDnsZones/virtualNetworkLinks')
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: hub.routing.networkId
    }
  }
}

// Required for Azure Data Explorer
// Create new DNS Zone if not using existing
resource queuePrivateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = if (hub.options.privateRouting && empty(hub.existingDnsZones.queue)) {
  name: string(hub.routing.dnsZones.queue.name)
  dependsOn: [
    vNet
  ]
  location: 'global'
  tags: getHubTags(hub, 'Microsoft.Storage/privateDnsZones')
  properties: {}
}

// Link to VNet (only needed for new zones; existing zones should already be linked)
resource queuePrivateDnsZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = if (hub.options.privateRouting && empty(hub.existingDnsZones.queue)) {
  parent: queuePrivateDnsZone
  name: '${replace(queuePrivateDnsZone.name, '.', '-')}-link'
  location: 'global'
  tags: getHubTags(hub, 'Microsoft.Network/privateDnsZones/virtualNetworkLinks')
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: hub.routing.networkId
    }
  }
}

// Required for Azure Data Explorer
// Create new DNS Zone if not using existing
resource tablePrivateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = if (hub.options.privateRouting && empty(hub.existingDnsZones.table)) {
  name: string(hub.routing.dnsZones.table.name)
  dependsOn: [
    vNet
  ]
  location: 'global'
  tags: getHubTags(hub, 'Microsoft.Storage/privateDnsZones')
  properties: {}
}

// Link to VNet (only needed for new zones; existing zones should already be linked)
resource tablePrivateDnsZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = if (hub.options.privateRouting && empty(hub.existingDnsZones.table)) {
  parent: tablePrivateDnsZone
  name: '${replace(tablePrivateDnsZone.name, '.', '-')}-link'
  location: 'global'
  tags: getHubTags(hub, 'Microsoft.Network/privateDnsZones/virtualNetworkLinks')
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: hub.routing.networkId
    }
  }
}

//------------------------------------------------------------------------------
// Script storage
//------------------------------------------------------------------------------

resource scriptStorageAccount 'Microsoft.Storage/storageAccounts@2022-09-01' = if (hub.options.privateRouting) {
  name: hub.routing.scriptStorage
  dependsOn: [
    vNet::scriptSubnet
  ]
  location: hub.location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  tags: getHubTags(hub, 'Microsoft.Storage/storageAccounts')
  properties: {
    supportsHttpsTrafficOnly: true
    allowSharedKeyAccess: true
    isHnsEnabled: false
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
      virtualNetworkRules: [
        {
          id: hub.routing.subnets.scripts
          action: 'Allow'
        }
      ]
    }
  }
}

resource scriptEndpoint 'Microsoft.Network/privateEndpoints@2023-11-01' = if (hub.options.privateRouting) {
  name: getPrivateEndpointName(hub, scriptStorageAccount.name, 'script-blob')
  dependsOn: [
    vNet::scriptSubnet
  ]
  location: hub.location
  tags: getHubTags(hub, 'Microsoft.Network/privateEndpoints')
  properties: {
    subnet: {
      id: hub.routing.subnets.storage
    }
    privateLinkServiceConnections: [
      {
        name: 'scriptLink'
        properties: {
          privateLinkServiceId: scriptStorageAccount.id
          groupIds: ['blob']
        }
      }
    ]
  }
  
  resource scriptPrivateDnsZoneGroup 'privateDnsZoneGroups' = {
    name: 'blob-endpoint-zone'
    properties: {
      privateDnsZoneConfigs: [
        {
          name: string(hub.routing.dnsZones.blob.name)
          properties: {
            privateDnsZoneId: !empty(hub.existingDnsZones.blob) ? hub.existingDnsZones.blob : blobPrivateDnsZone.id
          }
        }
      ]
    }
  }
}


//==============================================================================
// Output
//==============================================================================

@description('FinOps hub configuration settings.')
output config HubProperties = hub

@description('Resource ID of the virtual network.')
output vNetId string = !hub.options.privateRouting ? '' : (useExistingVNet ? hub.existingNetwork.virtualNetworkId : vNet.id)

@description('Virtual network address prefixes.')
#disable-next-line BCP318 // Null safety warning for conditional resource access
output vNetAddressSpace array = !hub.options.privateRouting || useExistingVNet ? [] : vNet.properties.addressSpace.addressPrefixes

@description('Virtual network subnets.')
#disable-next-line BCP318 // Null safety warning for conditional resource access
output vNetSubnets array = !hub.options.privateRouting || useExistingVNet ? [] : vNet.properties.subnets

@description('Resource ID of the FinOps hub network subnet.')
output finopsHubSubnetId string = !hub.options.privateRouting ? '' : (useExistingVNet ? hub.existingNetwork.privateEndpointSubnetId : vNet::finopsHubSubnet.id)

@description('Resource ID of the script storage account network subnet.')
output scriptSubnetId string = !hub.options.privateRouting ? '' : (useExistingVNet ? hub.existingNetwork.scriptSubnetId : vNet::scriptSubnet.id)

@description('Resource ID of the Data Explorer network subnet.')
output dataExplorerSubnetId string = !hub.options.privateRouting ? '' : (useExistingVNet ? hub.existingNetwork.dataExplorerSubnetId : vNet::dataExplorerSubnet.id)
