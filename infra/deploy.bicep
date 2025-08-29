@description('Resource group location')
param location string = resourceGroup().location

@minLength(2)
@maxLength(13)
param suffix string = uniqueString(resourceGroup().id)

@description('Name of the AKS cluster')
@maxLength(63)
param aksName string = 'aks-${suffix}'

@description('Name of the storage account')
@minLength(3)
@maxLength(24)
param storageAccountName string = 'blob${suffix}'

@description('Name of the container registry')
@minLength(5)
@maxLength(50)
param acrName string = 'acr${suffix}'

param aksVMSku string = 'Standard_D8as_v5'

@description('Virtual network address space')
param vnetAddressSpace string = '10.0.0.0/16'

@description('AKS subnet address space')
param aksSubnetAddressSpace string = '10.0.10.0/24'

@description('Name of the virtual network')
param vnetName string = 'vnet-${suffix}'

@description('Optional: Resource ID of existing subnet for AKS nodes. If provided, VNet creation will be skipped.')
param existingSubnetId string = ''

resource vnet 'Microsoft.Network/virtualNetworks@2024-07-01' = if (empty(existingSubnetId)) {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressSpace
      ]
    }
  }
}

resource aksSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-07-01' = if (empty(existingSubnetId)) {
  parent: vnet
  name: 'aks-subnet'
  properties: {
    addressPrefix: aksSubnetAddressSpace
  }
}

resource acr 'Microsoft.ContainerRegistry/registries@2025-04-01' = {
  name: acrName
  sku: {
    name: 'Basic'
  }
  location: location
  properties: {
    adminUserEnabled: true
  }
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2025-01-01' = {
  name: storageAccountName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Allow'
    }
  }
}

resource fileServices 'Microsoft.Storage/storageAccounts/fileServices@2025-01-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    shareDeleteRetentionPolicy: {
      enabled: false
    }
  }
}

resource configShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2025-01-01' = {
  parent: fileServices
  name: 'config'
  properties: {
    accessTier: 'Hot'
    enabledProtocols: 'SMB'
  }
}

// AKS Cluster with 2 node pools using dedicated VNet subnet
resource aks 'Microsoft.ContainerService/managedClusters@2025-05-01' = {
  name: aksName
  location: location
  sku: {
    name: 'Base'
    tier: 'Standard'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    dnsPrefix: '${aksName}-dns'
    agentPoolProfiles: [
      // System node pool
      {
        name: 'systempool'
        count: 1
        vmSize: aksVMSku
        osDiskSizeGB: 128
        osDiskType: 'Managed'
        kubeletDiskType: 'OS'
        osType: 'Linux'
        osSKU: 'Ubuntu'
        mode: 'System'
        type: 'VirtualMachineScaleSets'
        enableAutoScaling: false
        maxPods: 250  // Increased pod density with CNI Overlay
        vnetSubnetID: empty(existingSubnetId) ? aksSubnet.id : existingSubnetId
        nodeLabels: {
          app: 'system'
        }
        securityProfile: {
          enableVTPM: false
          enableSecureBoot: false
        }
      }
      // User node pool
      {
        name: 'locustworker'
        count: 2
        vmSize: aksVMSku
        osDiskSizeGB: 128
        osDiskType: 'Managed'
        kubeletDiskType: 'OS'
        type: 'VirtualMachineScaleSets'
        enableAutoScaling: false
        mode: 'User'
        osType: 'Linux'
        osSKU: 'Ubuntu'
        maxPods: 250  // Increased pod density with CNI Overlay
        vnetSubnetID: empty(existingSubnetId) ? aksSubnet.id : existingSubnetId
        nodeLabels: {
          app: 'locust-worker'
        }
      }
    ]
    nodeResourceGroup: '${resourceGroup().name}-${aksName}'
    storageProfile: {
      blobCSIDriver: { 
        enabled: true
      }
    }
    networkProfile: {
      networkPlugin: 'azure'
      networkPluginMode: 'overlay'  // Enable CNI Overlay mode
      networkPolicy: 'azure'
      networkDataplane: 'azure'
      loadBalancerSku: 'Standard'
      loadBalancerProfile: {
        managedOutboundIPs: {
          count: 1
        }
        backendPoolType: 'nodeIPConfiguration'
      }
      serviceCidr: '172.16.0.0/16'
      dnsServiceIP: '172.16.0.10'
      outboundType: 'loadBalancer'
      serviceCidrs: [
        '172.16.0.0/16'
      ]
      ipFamilies: [
        'IPv4'
      ]
      // Pod subnet for overlay networking
      podCidr: '10.244.0.0/16'
      podCidrs: [
        '10.244.0.0/16'
      ]
    }
    enableRBAC: true
  }
}

resource acrRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, aks.id, 'AcrPull')
  scope: acr
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d') // AcrPull
    principalId: aks.properties.identityProfile.kubeletidentity.objectId
    principalType: 'ServicePrincipal'
  }
}

output aksName string = aks.name
output storageAccountName string = storageAccount.name
output shareName string = configShare.name
output acrLogin string = acr.properties.loginServer
