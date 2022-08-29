#!/usr/bin/bash -e

REGION_NAME='southeastasia'
RESOURCE_GROUP='19th-Alan-FHIR_on_AKS'

VNET_NAME='vnet-fhir'
SUBNET_NAME='subnet-fhir'
VNET_RANGE='10.123.4.0/24'
SUBNET_RANGE='10.123.4.0/25'

AKS_CLUSTER_NAME='aks-fhir'
K8S_VERSION='1.21.9'

SQL_SERVER_NAME='alan0824-fhir'
SQL_SERVER_DB_NAME='FHIR'
SQL_SERVER_ADMIN_PASSWD='Zmhpcl9zZXJ2ZXJfYWRtaW4='
SQL_SERVER_ADMIN_USER='fhir_server_admin'

log() {
    echo "[SETUP] $1"
}

# create resource group
RESOURCE_GROUP_EXISTS=`az group exists --resource-group $RESOURCE_GROUP`
if [ "$RESOURCE_GROUP_EXISTS" = 'false' ]; then
    log "Creating resource group..."
    az group create --name $RESOURCE_GROUP --location $REGION_NAME --output none
fi

# create virtual network & get subnet id
# NOTE: need to change $RESOURCE_GROUP to lowercase here, or the vnet could not be found
VNET_NUM=`az network vnet list --query "[?(name=='$VNET_NAME'&&resourceGroup=='${RESOURCE_GROUP,,}')]" | jq '. | length'`
if [ $VNET_NUM -eq 0 ]; then
    log "Creating virtual network..."
    SUBNET_ID=`az network vnet create \
        --resource-group $RESOURCE_GROUP \
        --location $REGION_NAME \
        --name $VNET_NAME \
        --address-prefixes $VNET_RANGE \
        --subnet-name $SUBNET_NAME \
        --subnet-prefixes $SUBNET_RANGE \
        --query "newVNet.subnets[].id" -o tsv`
else
    SUBNET_ID=`az network vnet subnet show \
        --resource-group $RESOURCE_GROUP \
        --vnet-name $VNET_NAME \
        --name $SUBNET_NAME \
        --query "id" -o tsv`
fi

# create an AKS cluster
CLUSTER_NUM=`az aks list --query "[?(name=='$AKS_CLUSTER_NAME'&&resourceGroup=='$RESOURCE_GROUP')]" | jq '. | length'`
if [ $CLUSTER_NUM -eq 0 ]; then
    log "Creating AKS cluster..."
    az aks create \
        --resource-group $RESOURCE_GROUP \
        --name $AKS_CLUSTER_NAME \
        --node-vm-size Standard_D2s_v3 \
        --location $REGION_NAME \
        --vm-set-type VirtualMachineScaleSets \
        --load-balancer-sku standard \
        --enable-cluster-autoscaler \
        --min-count 3 \
        --max-count 5 \
        --generate-ssh-keys \
        --kubernetes-version $K8S_VERSION \
        --network-plugin azure \
        --vnet-subnet-id $SUBNET_ID \
        --service-cidr 10.2.0.0/24 \
        --dns-service-ip 10.2.0.10 \
        --docker-bridge-address 172.17.0.1/16 > /dev/null
fi

# configure AKS credentials
log "Configuring AKS credentials..."
az aks get-credentials --resource-group $RESOURCE_GROUP --name $AKS_CLUSTER_NAME

# Prepare a SQL server with a database
SERVER_NUM=`az sql server list --query "[?(name=='$SQL_SERVER_NAME'&&resourceGroup=='$RESOURCE_GROUP')]" | jq '. | length'`
if [ $SERVER_NUM -eq 0 ]; then
    # create a SQL server
    log "Creating SQL server..."
    az sql server create \
        --resource-group $RESOURCE_GROUP \
        --name $SQL_SERVER_NAME \
        --location $REGION_NAME \
        --admin-password $SQL_SERVER_ADMIN_PASSWD \
        --admin-user $SQL_SERVER_ADMIN_USER

    # create firewall rule for the SQL server
    log "Creating firewall rule..."
    az sql server firewall-rule create \
        --resource-group $RESOURCE_GROUP \
        --server $SQL_SERVER_NAME \
        --name "${SQL_SERVER_NAME}-firewall" \
        --start-ip-address 0.0.0.0 \
        --end-ip-address 0.0.0.0 \
        --output none

    # create a SQL database
    log "Creating SQL database..."
    az sql db create \
        --resource-group $RESOURCE_GROUP \
        --server $SQL_SERVER_NAME \
        --name $SQL_SERVER_DB_NAME \
        --output none
fi

# clone the repo of the fhir-server
if [ ! -d "fhir-server" ]; then
    git clone https://github.com/microsoft/fhir-server
fi

# install fhir-server
log "Installing/Upgrading FHIR server"
helm upgrade --install fhir-server ./fhir-server/samples/kubernetes/helm/fhir-server/ \
    --create-namespace \
    --namespace my-fhir-release \
    --set service.type=LoadBalancer \
    --set database.dataStore=ExistingSqlServer \
    --set database.existingSqlServer.serverName="${SQL_SERVER_NAME}.database.windows.net" \
    --set database.existingSqlServer.databaseName=$SQL_SERVER_DB_NAME \
    --set database.existingSqlServer.userName=$SQL_SERVER_ADMIN_USER \
    --set database.existingSqlServer.password=$SQL_SERVER_ADMIN_PASSWD \