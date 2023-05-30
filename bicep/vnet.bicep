param location string

param vnet_name string
param subnet_name string
param nsg_name string

param vnet_range string
param subnet_range string

output subnet_id string = subnet.id

resource vnet 'Microsoft.Network/virtualNetworks@2022-07-01' = {
  name: vnet_name
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnet_range
      ]
    }
  }
}

resource subnet 'Microsoft.Network/virtualNetworks/subnets@2022-07-01' = {
  name: subnet_name
  parent: vnet
  properties: {
    addressPrefix: subnet_range
    networkSecurityGroup: {
      id: nsg.id
    }
  }
}

resource nsg 'Microsoft.Network/networkSecurityGroups@2022-07-01' = {
  name: nsg_name
  location: location
}

var svcs = ['HTTP', 'HTTPS']
var ports = [80, 443]
var priors = [100, 110]

resource rules 'Microsoft.Network/networkSecurityGroups/securityRules@2022-07-01' = [for i in range(0, 2): {
  name: 'AllowAny${svcs[i]}Inbound'
  parent: nsg
  properties: {
    direction: 'Inbound'
    protocol: 'Tcp'
    sourceAddressPrefix: '*'
    sourcePortRange: '*'
    destinationAddressPrefix: '*'
    destinationPortRange: '${ports[i]}'
    access: 'Allow'
    priority: priors[i]
  }
}]
