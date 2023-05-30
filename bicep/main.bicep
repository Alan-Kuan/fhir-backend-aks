targetScope = 'subscription'

param deploy object = deployment()
param rg_name string

param vnet_range string
param subnet_range string

param sql_server_name string
param sql_server_db_name string
param sql_server_admin_user string
param sql_server_admin_passwd string

param k8s_version string

resource rg 'Microsoft.Resources/resourceGroups@2022-09-01' = {
  name: rg_name
  location: deploy.location
}

module vnet_module 'vnet.bicep' = {
  scope: rg
  name: 'vnet-deploy'
  params: {
    location: rg.location
    vnet_name: 'vnet-fhir'
    subnet_name: 'subnet-fhir'
    nsg_name: 'nsg-fhir'
    vnet_range: vnet_range
    subnet_range: subnet_range
  }
}

module aks 'aks.bicep' = {
  scope: rg
  name: 'aks-deploy'
  params: {
    location: rg.location
    aks_name: 'aks-fhir'
    k8s_version: k8s_version
    dns_prefix: 'aks-fhir'
    subnet_id: vnet_module.outputs.subnet_id
  }
}

module db_module 'db.bicep' = {
  scope: rg
  name: 'db-deploy'
  params: {
    location: rg.location
    sql_server_name: sql_server_name
    sql_server_db_name: sql_server_db_name
    sql_server_admin_user: sql_server_admin_user
    sql_server_admin_passwd: sql_server_admin_passwd
  }
}
