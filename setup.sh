#!/usr/bin/bash -e

log() {
    echo "[SETUP] $1"
}

if [ ! -f env.sh ]; then
    log "env.sh was not found. Coping from env.example.sh..."
    cp env.example.sh env.sh
    sed -i '1s/.*/# copied from env.example.sh, please fill in your values/' env.sh
    log "Please fill in your values first."
    exit 1
fi

source env.sh

# create resource group
RESOURCE_GROUP_EXISTS=`az group exists --resource-group $RESOURCE_GROUP`
if [ "$RESOURCE_GROUP_EXISTS" = 'false' ]; then
    log "Creating a resource group..."
    az group create --name $RESOURCE_GROUP --location $REGION_NAME --output none
fi

# create virtual network & get subnet id
VNET_NUM=`az network vnet list --query "[?(name=='$VNET_NAME'&&resourceGroup=='${RESOURCE_GROUP}')]" | jq '. | length'`
if [ "$VNET_NUM" -eq 0 ]; then
    log "Creating a virtual network..."
    az network vnet create \
        --resource-group $RESOURCE_GROUP \
        --location $REGION_NAME \
        --name $VNET_NAME \
        --address-prefixes $VNET_RANGE \
        --output none

    log "Creating a network security group..."
    az network nsg create \
        --resource-group $RESOURCE_GROUP \
        --location $REGION_NAME \
        --name $NSG_NAME \
        --output none

    log "Creating HTTP/HTTPS rules for the group..."
    az network nsg rule create \
        --resource-group $RESOURCE_GROUP \
        --nsg-name $NSG_NAME \
        --name AllowAnyHTTPInbound \
        --priority 100 \
        --access Allow \
        --destination-port-ranges 80 \
        --direction Inbound \
        --protocol TCP \
        --output none
    az network nsg rule create \
        --resource-group $RESOURCE_GROUP \
        --nsg-name $NSG_NAME \
        --name AllowAnyHTTPSInbound \
        --priority 100 \
        --access Allow \
        --destination-port-ranges 443 \
        --direction Inbound \
        --protocol TCP \
        --output none

    log "Creating a subnet in the virtual network..."
    SUBNET_ID=`az network vnet subnet create \
        --resource-group $RESOURCE_GROUP \
        --vnet-name $VNET_NAME \
        --name $SUBNET_NAME \
        --address-prefixes $SUBNET_RANGE \
        --network-security-group $NSG_NAME \
        --query "id" -o tsv`
else
    SUBNET_ID=`az network vnet subnet show \
        --resource-group $RESOURCE_GROUP \
        --vnet-name $VNET_NAME \
        --name $SUBNET_NAME \
        --query "id" -o tsv`
fi

# create an AKS cluster
CLUSTER_NUM=`az aks list --query "[?(name=='$AKS_CLUSTER_NAME'&&resourceGroup=='$RESOURCE_GROUP')]" | jq '. | length'`
if [ "$CLUSTER_NUM" -eq 0 ]; then
    log "Creating an AKS cluster..."
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
if [ "$SERVER_NUM" -eq 0 ]; then
    # create a SQL server
    log "Creating a SQL server..."
    az sql server create \
        --resource-group $RESOURCE_GROUP \
        --name $SQL_SERVER_NAME \
        --location $REGION_NAME \
        --admin-password $SQL_SERVER_ADMIN_PASSWD \
        --admin-user $SQL_SERVER_ADMIN_USER \
        --output none

    # create firewall rules for the SQL server
    # NOTE: As described in the doc, if start-ip-address and end-ip-address are 0.0.0.0,
    #       it allows all Azure-internal IP address. 
    log "Creating firewall rules..."
    az sql server firewall-rule create \
        --resource-group $RESOURCE_GROUP \
        --server $SQL_SERVER_NAME \
        --name "${SQL_SERVER_NAME}-firewall" \
        --start-ip-address 0.0.0.0 \
        --end-ip-address 0.0.0.0 \
        --output none

    # create a SQL database
    log "Creating a SQL database..."
    az sql db create \
        --resource-group $RESOURCE_GROUP \
        --server $SQL_SERVER_NAME \
        --name $SQL_SERVER_DB_NAME \
        --edition GeneralPurpose \
        --family Gen5 \
        --capacity 1 \
        --compute-model Serverless \
        --max-size 1GB \
        --auto-pause-delay 60 \
        --backup-storage-redundancy Geo \
        --output none
fi

# install fhir-server
FHIR_SERVER_NUM=`kubectl get all -n my-fhir-release -o json | jq '.items | length'`
if [ "$FHIR_SERVER_NUM" -eq 0 ]; then
    log "Installing the FHIR server..."
    helm upgrade --install fhir-server ./fhir-server/samples/kubernetes/helm/fhir-server/ \
        --create-namespace \
        --namespace my-fhir-release \
        --set database.dataStore=ExistingSqlServer \
        --set database.existingSqlServer.serverName="${SQL_SERVER_NAME}.database.windows.net" \
        --set database.existingSqlServer.databaseName=$SQL_SERVER_DB_NAME \
        --set database.existingSqlServer.userName=$SQL_SERVER_ADMIN_USER \
        --set database.existingSqlServer.password=$SQL_SERVER_ADMIN_PASSWD
fi

# Update helm repo list
log "Updating helm repo list..."
helm repo add jetstack https://charts.jetstack.io
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

# install cert-manager
CERT_MANAGER_NUM=`kubectl get all -n cert-manager -o json | jq '.items | length'`
if [ "$CERT_MANAGER_NUM" -eq 0 ]; then
    helm upgrade --install cert-manager jetstack/cert-manager \
      --create-namespace \
      --namespace cert-manager \
      --version $CERT_MANAGER_VERSION \
      --set installCRDs=true
fi

# create an Let's Encrypt Issuer
if ! kubectl get issuer letsencrypt-prod -n my-fhir-release >/dev/null 2>&1; then
    log "Creating an Let's Encrypt Issuer..."
    kubectl apply -f issuer-fhir.yml
fi

# install NGINX Ingress Controller
INGRESS_CONTROLLER_NUM=`kubectl get all -n ingress-basic -o json | jq '.items | length'`
if [ "$INGRESS_CONTROLLER_NUM" -eq 0 ]; then
    log "Installing NGINX Ingress Controller..."
    helm upgrade --install nginx-ingress ingress-nginx/ingress-nginx \
        --create-namespace \
        --namespace ingress-basic \
        --set controller.replicaCount=2 \
        --set controller.nodeSelector."kubernetes\.io/os"=linux \
        --set defaultBackend.nodeSelector."kubernetes\.io/os"=linux \
        --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-dns-label-name"=$API_DNS_LABEL
fi

# create account for basic auth
if ! kubectl get secret basic-auth >/dev/null 2>&1; then
    if ! command -v htpasswd >/dev/null; then
        log "'htpasswd' is a necessary command. You can install 'apache2-utils' on Ubuntu for it."
        exit 1
    fi

    log "Creating an account for basic auth..."
    echo -n "Username: "
    read -r uname
    htpasswd -c auth $uname
    kubectl create secret generic basic-auth --from-file=auth
fi

# create a ingress route
INGRESS_NUM=`kubectl get ingress -n my-fhir-release -o json | jq '.items | length'`
if [ "$INGRESS_NUM" -eq 0 ]; then
    log "Creating a route to the FHIR server"
    envsubst < ingress-fhir.yml | kubectl apply -f -
fi
