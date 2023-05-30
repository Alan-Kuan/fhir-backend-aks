param location string

param sql_server_name string
param sql_server_db_name string
param sql_server_admin_user string
param sql_server_admin_passwd string

resource sql_server 'Microsoft.Sql/servers@2021-11-01' = {
  name: sql_server_name
  location: location
  properties: {
    administratorLogin: sql_server_admin_user
    administratorLoginPassword: sql_server_admin_passwd
  }
}

resource sql_db 'Microsoft.Sql/servers/databases@2021-11-01' = {
  name: sql_server_db_name
  location: location
  parent: sql_server
  sku: {
    name: 'Basic'
    tier: 'Basic'
  }
  properties: {
    requestedBackupStorageRedundancy: 'Geo'
  }
}

// NOTE: As described in the doc, if start-ip-address and end-ip-address are 0.0.0.0,
//       it allows all Azure-internal IP address.
resource sql_firewall_rule 'Microsoft.Sql/servers/firewallRules@2021-11-01' = {
  name: '${sql_server_name}-firewall'
  parent: sql_server
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}
