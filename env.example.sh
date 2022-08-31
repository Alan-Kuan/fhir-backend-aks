# copy this file into env.sh and fill in your value
REGION_NAME='southeastasia'
RESOURCE_GROUP='someRG'

VNET_NAME='vnet-fhir'
SUBNET_NAME='subnet-fhir'
NSG_NAME='nsg-fhir'
VNET_RANGE='10.123.4.0/24'
SUBNET_RANGE='10.123.4.0/25'

AKS_CLUSTER_NAME='aks-fhir'
K8S_VERSION='1.22.6'

SQL_SERVER_NAME='sql-server-fhir'
SQL_SERVER_DB_NAME='FHIR'
SQL_SERVER_ADMIN_PASSWD='sql_server_admin_passwd'
SQL_SERVER_ADMIN_USER='sql_server_admin'
