# copy this file into env.sh and fill in your value
export REGION_NAME='southeastasia'
export RESOURCE_GROUP='someRG'

export VNET_NAME='vnet-fhir'
export SUBNET_NAME='subnet-fhir'
export NSG_NAME='nsg-fhir'
export VNET_RANGE='10.123.4.0/24'
export SUBNET_RANGE='10.123.4.0/25'

export AKS_CLUSTER_NAME='aks-fhir'
export K8S_VERSION='1.22.6'
export CERT_MANAGER_VERSION='v1.9.1'
export INGRESS_NAME='ingress-fhir'
export API_DNS_LABEL='fhir-demo'

export SQL_SERVER_NAME='sql-server-fhir'
export SQL_SERVER_DB_NAME='FHIR'
export SQL_SERVER_ADMIN_PASSWD='sql_server_admin_passwd'
export SQL_SERVER_ADMIN_USER='sql_server_admin'

export ACME_REG_EMAIL=xxx@ooo.com
export KUBECONFIG=/home/xxx/.kube/config
