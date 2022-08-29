#!/usr/bin/bash -e

REGION_NAME='southeastasia'
RESOURCE_GROUP='19th-Alan-FHIR_on_AKS'

VNET_NAME='vnet-fhir'
SUBNET_NAME='subnet-fhir'
VNET_RANGE='10.123.4.0/24'
SUBNET_RANGE='10.123.4.0/25'

SP_NAME='sp-fhir'

AKS_CLUSTER_NAME='aks-fhir'
K8S_VERSION='1.21.9'
CERT_MANAGER_VERSION='v0.12.0'

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

# add repos of cert-manager and Azure service operator
log "Updating Helm repos..."
helm repo add jetstack https://charts.jetstack.io
helm repo add aso https://raw.githubusercontent.com/Azure/azure-service-operator/main/charts
helm repo update

# install cert-manager
log "Installing/Upgrading cert-manager..."
helm upgrade --install cert-manager jetstack/cert-manager \
    --create-namespace \
    --namespace cert-manager \
    --version $CERT_MANAGER_VERSION \
    --set installCRDs=true

ACCOUNT_DETAILS=`az account show`
TENANT_ID=`echo $ACCOUNT_DETAILS | jq -r '.tenantId'`
SUBSCRIPTION_ID=`echo $ACCOUNT_DETAILS | jq -r '.id'`

# create service principal
log "Creating service principal..."
SERVICE_PRINCIPAL=`az ad sp create-for-rbac \
    --name $SP_NAME \
    --role contributor \
    --scopes /subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP`

CLIENT_ID=`echo $SERVICE_PRINCIPAL | jq -r '.appId'`
CLIENT_SECRET=`echo $SERVICE_PRINCIPAL | jq -r '.password'`

# install Azure Service Operator
log "Installing/Upgrading Azure Service Operator..."
helm upgrade --install aso aso/azure-service-operator \
    --create-namespace \
    --namespace azureoperator-system \
    --set azureSubscriptionID=$SUBSCRIPTION_ID \
    --set azureTenantID=$TENANT_ID \
    --set azureClientID=$CLIENT_ID \
    --set azureClientSecret=$CLIENT_SECRET

# clone the repo of the fhir-server
if [ ! -d "fhir-server" ]; then
    git clone https://github.com/microsoft/fhir-server
    # TODO: update fhir-server name
fi

# install fhir-server
log "Installing/Upgrading FHIR server"
helm upgrade --install fhir-server ./fhir-server/samples/kubernetes/helm/fhir-server/ \
    --create-namespace \
    --namespace my-fhir-release \
    --set service.type=LoadBalancer \
    --set database.resourceGroup=$RESOURCE_GROUP \
    --set database.location=$REGION_NAME \
