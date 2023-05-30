param location string

param aks_name string
param k8s_version string
param dns_prefix string
param node_count int = 1
param vm_size string = 'standard_d2s_v3'
param subnet_id string
// NOTE: we can try basic later, https://learn.microsoft.com/en-us/azure/load-balancer/skus
param load_balancer_sku string = 'standard'

resource aks 'Microsoft.ContainerService/managedClusters@2022-09-01' = {
  name: aks_name
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    kubernetesVersion: k8s_version
    dnsPrefix: dns_prefix
    agentPoolProfiles: [
      {
        name: 'nodepool'
        type: 'VirtualMachineScaleSets'
        count: node_count
        vmSize: vm_size
        osType: 'Linux'
        mode: 'System'
        vnetSubnetID: subnet_id
      }
    ]
    networkProfile: {
      loadBalancerSku: load_balancer_sku
      networkPlugin: 'azure'
      serviceCidr: '10.2.0.0/24'
      dnsServiceIP: '10.2.0.10'
      dockerBridgeCidr: '172.17.0.1/16'
    }
  }
}
