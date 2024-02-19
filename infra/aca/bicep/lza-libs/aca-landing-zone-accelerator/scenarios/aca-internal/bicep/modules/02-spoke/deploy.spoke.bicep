targetScope = 'subscription'

// ------------------
//    PARAMETERS
// ------------------

@description('The name of the workload that is being deployed. Up to 10 characters long.')
@minLength(2)
@maxLength(10)
param workloadName string

@description('The name of the environment (e.g. "dev", "test", "prod", "uat", "dr", "qa"). Up to 8 characters long.')
@maxLength(8)
param environment string

@description('The location where the resources will be created. This should be the same region as the hub.')
param location string = deployment().location

@description('Optional. The name of the resource group to create the resources in. If set, it overrides the name generated by the template.')
param spokeResourceGroupName string

@description('Optional. The tags to be assigned to the created resources.')
param tags object = {}

// Hub
@description('The resource ID of the existing hub virtual network.')
param hubVNetId string

// Spoke
@description('CIDR of the spoke virtual network. For most landing zone implementations, the spoke network would have been created by your platform team.')
param spokeVNetAddressPrefixes array

@description('Optional. The name of the subnet to create for the spoke infrastructure. If set, it overrides the name generated by the template.')
param spokeInfraSubnetName string = 'snet-infra'

@description('CIDR of the spoke infrastructure subnet.')
param spokeInfraSubnetAddressPrefix string

@description('Optional. The name of the subnet to create for the spoke private endpoints. If set, it overrides the name generated by the template.')
param spokePrivateEndpointsSubnetName string = 'snet-pep'

@description('CIDR of the spoke private endpoints subnet.')
param spokePrivateEndpointsSubnetAddressPrefix string

@description('Optional. The name of the subnet to create for the spoke application gateway. If set, it overrides the name generated by the template.')
param spokeApplicationGatewaySubnetName string = 'snet-agw'

@description('CIDR of the spoke Application Gateway subnet. If the value is empty, this subnet will not be created.')
param spokeApplicationGatewaySubnetAddressPrefix string

@description('The IP address of the network appliance (e.g. firewall) that will be used to route traffic to the internet.')
param networkApplianceIpAddress string

@description('The size of the jump box virtual machine to create. See https://learn.microsoft.com/azure/virtual-machines/sizes for more information.')
param vmSize string

@description('The username to use for the jump box.')
param vmAdminUsername string

@description('The password to use for the jump box.')
@secure()
param vmAdminPassword string

@description('The SSH public key to use for the jump box. Only relevant for Linux.')
@secure()
param vmLinuxSshAuthorizedKeys string

@description('The OS of the jump box virtual machine to create. If set to "none", no jump box will be created.')
@allowed([ 'linux', 'windows', 'none' ])
param vmJumpboxOSType string = 'none'

@description('Optional. The name of the subnet to create for the jump box. If set, it overrides the name generated by the template.')
param vmSubnetName string = 'snet-jumpbox'

@description('CIDR to use for the jump box subnet.')
param vmJumpBoxSubnetAddressPrefix string

@description('Optional, default value is true. If true, Azure Policies will be deployed')
param deployAzurePolicies bool = true

// ------------------
// VARIABLES
// ------------------

//Destination Service Tag for AzureCloud for Central France is centralfrance, but location is francecentral
var locationVar = location == 'francecentral' ? 'centralfrance' : location

// load as text (and not as Json) to replace <location> placeholder in the nsg rules
var nsgCaeRules = json( replace( loadTextContent('./nsgContainerAppsEnvironment.jsonc') , '<location>', locationVar) )
var nsgAppGwRules = loadJsonContent('./nsgAppGwRules.jsonc', 'securityRules')
var namingRules = json(loadTextContent('../../../../shared/bicep/naming/naming-rules.jsonc'))

var rgSpokeName = !empty(spokeResourceGroupName) ? spokeResourceGroupName : '${namingRules.resourceTypeAbbreviations.resourceGroup}-${workloadName}-spoke-${environment}-${namingRules.regionAbbreviations[toLower(location)]}'
var hubVNetResourceIdTokens = !empty(hubVNetId) ? split(hubVNetId, '/') : array('')

@description('The ID of the subscription containing the hub virtual network.')
var hubSubscriptionId = hubVNetResourceIdTokens[2]

@description('The name of the resource group containing the hub virtual network.')
var hubResourceGroupName = hubVNetResourceIdTokens[4]

@description('The name of the hub virtual network.')
var hubVNetName = hubVNetResourceIdTokens[8]

// Subnet definition taking in consideration feature flags
var defaultSubnets = [
  {
    name: spokeInfraSubnetName
    properties: {
      addressPrefix: spokeInfraSubnetAddressPrefix
      networkSecurityGroup: {
        id: nsgContainerAppsEnvironment.outputs.nsgId
      }
      routeTable: {
        id: egressLockdownUdr.outputs.resourceId
      }
      delegations: [
        {
          name: 'envdelegation'
          properties: {
            serviceName: 'Microsoft.App/environments'
          }
        }
      ]
    }
  }
  {
    name: spokePrivateEndpointsSubnetName
    properties: {
      addressPrefix: spokePrivateEndpointsSubnetAddressPrefix
      networkSecurityGroup: {
        id: nsgPep.outputs.nsgId
      }
    }
  }
]

// Append optional application gateway subnet, if required
var appGwAndDefaultSubnets = !empty(spokeApplicationGatewaySubnetAddressPrefix) ? concat(defaultSubnets, [
    {
      name: spokeApplicationGatewaySubnetName
      properties: {
        addressPrefix: spokeApplicationGatewaySubnetAddressPrefix
        networkSecurityGroup: {
          id: nsgAppGw.outputs.nsgId
        }
      }
    }
  ]) : defaultSubnets

  //Append optional jumpbox subnet, if required
var spokeSubnets = vmJumpboxOSType != 'none' ? concat(appGwAndDefaultSubnets, [
    {
      name: vmSubnetName
      properties: {
        addressPrefix: vmJumpBoxSubnetAddressPrefix
      }
    }
  ]) : appGwAndDefaultSubnets

// ------------------
// RESOURCES
// ------------------


@description('The spoke resource group. This would normally be already provisioned by your subscription vending process.')
resource spokeResourceGroup 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: rgSpokeName
  location: location
  tags: tags
}

@description('User-configured naming rules')
module naming '../../../../shared/bicep/naming/naming.module.bicep' = {
  scope: spokeResourceGroup
  name: take('02-sharedNamingDeployment-${deployment().name}', 64)
  params: {
    uniqueId: uniqueString(spokeResourceGroup.id)
    environment: environment
    workloadName: workloadName
    location: location
  }
}

@description('The spoke virtual network in which the workload will run from. This virtual network would normally already be provisioned by your subscription vending process, and only the subnets would need to be configured.')
module vnetSpoke '../../../../shared/bicep/network/vnet.bicep' = {
  name: take('vnetSpoke-${deployment().name}', 64)
  scope: spokeResourceGroup
  params: {
    name: naming.outputs.resourcesNames.vnetSpoke
    location: location
    tags: tags
    subnets: spokeSubnets
    vnetAddressPrefixes: spokeVNetAddressPrefixes
  }
}

@description('The log sink for Azure Diagnostics')
module logAnalyticsWorkspace '../../../../shared/bicep/log-analytics-ws.bicep' = {
  name: take('logAnalyticsWs-${uniqueString(spokeResourceGroup.id)}', 64)
  scope: spokeResourceGroup
  params: {
    location: location
    name: naming.outputs.resourcesNames.logAnalyticsWorkspace
  }
}

@description('Network security group rules for the Container Apps cluster.')
module nsgContainerAppsEnvironment '../../../../shared/bicep/network/nsg.bicep' = {
  name: take('nsgContainerAppsEnvironment-${deployment().name}', 64)
  scope: spokeResourceGroup
  params: {
    name: naming.outputs.resourcesNames.containerAppsEnvironmentNsg
    location: location
    tags: tags
    securityRules: nsgCaeRules.securityRules
    diagnosticWorkspaceId: logAnalyticsWorkspace.outputs.logAnalyticsWsId
  }
}

@description('NSG Rules for the Application Gateway.')
module nsgAppGw '../../../../shared/bicep/network/nsg.bicep' = if (!empty(spokeApplicationGatewaySubnetAddressPrefix)) {
  name: take('nsgAppGw-${deployment().name}', 64)
  scope: spokeResourceGroup
  params: {
    name: naming.outputs.resourcesNames.applicationGatewayNsg
    location: location
    tags: tags
    securityRules: nsgAppGwRules
    diagnosticWorkspaceId: logAnalyticsWorkspace.outputs.logAnalyticsWsId
  }
}

@description('NSG Rules for the private enpoint subnet.')
module nsgPep '../../../../shared/bicep/network/nsg.bicep' = {
  name: take('nsgPep-${deployment().name}', 64)
  scope: spokeResourceGroup
  params: {
    name: naming.outputs.resourcesNames.pepNsg
    location: location
    tags: tags
    securityRules: []
    diagnosticWorkspaceId: logAnalyticsWorkspace.outputs.logAnalyticsWsId
  }
}

@description('Spoke peering to regional hub network. This peering would normally already be provisioned by your subscription vending process.')
module peerSpokeToHub '../../../../shared/bicep/network/peering.bicep' = if (!empty(hubVNetId))  {
  name: take('${deployment().name}-peerSpokeToHubDeployment', 64)
  scope: spokeResourceGroup
  params: {
    localVnetName: vnetSpoke.outputs.vnetName
    remoteSubscriptionId: hubSubscriptionId
    remoteRgName: hubResourceGroupName
    remoteVnetName: hubVNetName
  }
}

@description('Regional hub peering to this spoke network. This peering would normally already be provisioned by your subscription vending process.')
module peerHubToSpoke '../../../../shared/bicep/network/peering.bicep' = if (!empty(hubVNetId)) {
  name: take('${deployment().name}-peerHubToSpokeDeployment', 64)
  scope: resourceGroup(hubSubscriptionId, hubResourceGroupName)
  params: {
    localVnetName: hubVNetName
    remoteSubscriptionId: last(split(subscription().id, '/'))!
    remoteRgName: spokeResourceGroup.name
    remoteVnetName: vnetSpoke.outputs.vnetName
  }
}
@description('The Route Table deployment')
module egressLockdownUdr '../../../../shared/bicep/routeTables/main.bicep' = {
  name: take('egressLockdownUdr-${uniqueString(spokeResourceGroup.id)}', 64)
  scope: spokeResourceGroup
  params: {
    name: naming.outputs.resourcesNames.routeTable
    location: location
    tags: tags
    routes: [
      {
        name: 'defaultEgressLockdown'
        properties: {
          addressPrefix: '0.0.0.0/0'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: networkApplianceIpAddress
        }
      }
    ]
  }
}


@description('An optional Linux virtual machine deployment to act as a jump box.')
module jumpboxLinuxVM './modules/vm/linux-vm.bicep' = if (vmJumpboxOSType == 'linux') {
  name: take('vm-linux-${deployment().name}', 64)
  scope: spokeResourceGroup
  params: {
    location: location
    tags: tags
    vmName: naming.outputs.resourcesNames.vmJumpBox
    vmAdminUsername: vmAdminUsername
    vmAdminPassword: vmAdminPassword
    vmSshPublicKey: vmLinuxSshAuthorizedKeys
    vmSize: vmSize
    vmVnetName: vnetSpoke.outputs.vnetName
    vmSubnetName: vmSubnetName
    vmSubnetAddressPrefix: vmJumpBoxSubnetAddressPrefix
    vmNetworkInterfaceName: naming.outputs.resourcesNames.vmJumpBoxNic
    vmNetworkSecurityGroupName: naming.outputs.resourcesNames.vmJumpBoxNsg
  }
}

@description('An optional Windows virtual machine deployment to act as a jump box.')
module jumpboxWindowsVM './modules/vm/windows-vm.bicep' = if (vmJumpboxOSType == 'windows') {
  name: take('vm-windows-${deployment().name}', 64)
  scope: spokeResourceGroup
  params: {
    location: location
    tags: tags
    vmName: naming.outputs.resourcesNames.vmJumpBox
    vmAdminUsername: vmAdminUsername
    vmAdminPassword: vmAdminPassword
    vmSize: vmSize
    vmVnetName: vnetSpoke.outputs.vnetName
    vmSubnetName: vmSubnetName
    vmSubnetAddressPrefix: vmJumpBoxSubnetAddressPrefix
    vmNetworkInterfaceName: naming.outputs.resourcesNames.vmJumpBoxNic
    vmNetworkSecurityGroupName: naming.outputs.resourcesNames.vmJumpBoxNsg
  }
}

@description('Assign built-in and custom (container-apps related) policies to the spoke subscription.')
module policyAssignments './modules/policy/policy-definition.module.bicep' = if (deployAzurePolicies) {
  name: take('policyAssignments-${deployment().name}', 64)
  scope: spokeResourceGroup
  params: {
    location: location   
    containerRegistryName: naming.outputs.resourcesNames.containerRegistry 
  }
}

// ------------------
// OUTPUTS
// ------------------

resource vnetSpokeCreated 'Microsoft.Network/virtualNetworks@2022-07-01' existing = {
  name: vnetSpoke.outputs.vnetName
  scope: spokeResourceGroup

  resource spokeInfraSubnet 'subnets' existing = {
    name: spokeInfraSubnetName
  }

  resource spokePrivateEndpointsSubnet 'subnets' existing = {
    name: spokePrivateEndpointsSubnetName
  }

  resource spokeApplicationGatewaySubnet 'subnets' existing = if (!empty(spokeApplicationGatewaySubnetAddressPrefix)) {
    name: spokeApplicationGatewaySubnetName
  }
}

@description('The name of the spoke resource group.')
output spokeResourceGroupName string = spokeResourceGroup.name

@description('The resource ID of the spoke virtual network.')
output spokeVNetId string = vnetSpokeCreated.id

@description('The name of the spoke virtual network.')
output spokeVNetName string = vnetSpokeCreated.name

@description('The resource ID of the spoke infrastructure subnet.')
output spokeInfraSubnetId string = vnetSpokeCreated::spokeInfraSubnet.id

@description('The name of the spoke infrastructure subnet.')
output spokeInfraSubnetName string = vnetSpokeCreated::spokeInfraSubnet.name

@description('The name of the spoke private endpoints subnet.')
output spokePrivateEndpointsSubnetName string = vnetSpokeCreated::spokePrivateEndpointsSubnet.name

@description('The resource ID of the spoke Application Gateway subnet. This is \'\' if the subnet was not created.')
output spokeApplicationGatewaySubnetId string = (!empty(spokeApplicationGatewaySubnetAddressPrefix)) ? vnetSpokeCreated::spokeApplicationGatewaySubnet.id : ''

@description('The name of the spoke Application Gateway subnet.  This is \'\' if the subnet was not created.')
output spokeApplicationGatewaySubnetName string = (!empty(spokeApplicationGatewaySubnetAddressPrefix)) ? vnetSpokeCreated::spokeApplicationGatewaySubnet.name : ''

@description('The resource ID of the Azure Log Analytics Workspace.')
output logAnalyticsWorkspaceId string = logAnalyticsWorkspace.outputs.logAnalyticsWsId

@description('The name of the jump box virtual machine')
output vmJumpBoxName string = naming.outputs.resourcesNames.vmJumpBox
