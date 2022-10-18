#!/usr/bin/bash -e

source utils.sh

# check whether necessary commands exist
required_cmds="az helm kubectl kubelogin jq htpasswd"
for cmd in $required_cmds; do
    if ! command -v $cmd >/dev/null; then
        log "'$cmd' is a necessary command."
        [ $cmd = "htpasswd" ] && log "You can install 'apache2-utils' on Ubuntu for it."
        exit 1
    fi
done

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
if ! az_resource_exists $RESOURCE_GROUP $VNET_NAME network vnet; then
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
if ! az_resource_exists $RESOURCE_GROUP $AKS_CLUSTER_NAME aks; then
    log "Creating an AKS cluster..."
    az aks create \
        --resource-group $RESOURCE_GROUP \
        --name $AKS_CLUSTER_NAME \
        --node-vm-size Standard_D2s_v3 \
        --location $REGION_NAME \
        --vm-set-type VirtualMachineScaleSets \
        --load-balancer-sku standard \
        --node-count 1 \
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
az aks get-credentials -g $RESOURCE_GROUP -n $AKS_CLUSTER_NAME
kubelogin convert-kubeconfig -l azurecli

# Prepare a SQL server with a database
if az_resource_exists $RESOURCE_GROUP $SQL_SERVER_NAME sql server; then
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
        --edition Basic \
        --max-size 1GB \
        --backup-storage-redundancy Geo \
        --output none
fi

# Update helm repo list
log "Updating helm repo list..."
helm repo add jetstack https://charts.jetstack.io
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo add aad-pod-identity https://raw.githubusercontent.com/Azure/aad-pod-identity/master/charts
helm repo update

# install add-pod-identity
if ! helm_release_exists aad-pod-identity; then
    helm install aad-pod-identity aad-pod-identity/aad-pod-identity
fi

NODE_RESOURCE_GROUP=`kubectl get nodes -o json | jq -r '.items[0].metadata.labels."kubernetes.azure.com/cluster"'`
# create identity for FHIR server
if ! az_resource_exists $NODE_RESOURCE_GROUP $IDENT_NAME identity; then
    IDENT=`az identity create -g $NODE_RESOURCE_GROUP -n $IDENT_NAME`
else
    IDENT=`az identity show -g $NODE_RESOURCE_GROUP -n $IDENT_NAME`
fi
IDENT_CLIENT_ID=`echo $IDENT | jq -r '.clientId'`
IDENT_RESOURCE_ID=`echo $IDENT | jq -r '.id'`

# create a storage account and assign it to the identity
if ! az_resource_exists $NODE_RESOURCE_GROUP $STORAGE_ACCOUNT_NAME storage account; then
    STORAGE_ACCOUNT=`az storage account create -g $NODE_RESOURCE_GROUP -n $STORAGE_ACCOUNT_NAME`
    STORAGE_ACCOUNT_ID=`echo $STORAGE_ACCOUNT | jq -r '.id'`
    az role assignment create \
        --role "Storage Blob Data Contributor" \
        --assignee $IDENT_CLIENT_ID \
        --scope $STORAGE_ACCOUNT_ID \
        --output none
else
    STORAGE_ACCOUNT=`az storage account show -g $NODE_RESOURCE_GROUP -n $STORAGE_ACCOUNT_NAME`
fi
BLOB_STORAGE_URI=`echo $STORAGE_ACCOUNT | jq -r '.primaryEndpoints.blob'`

# install fhir-server
if ! helm_release_exists fhir-server; then
    log "Installing the FHIR server..."
    helm upgrade --install fhir-server ./fhir-server/samples/kubernetes/helm/fhir-server/ \
        --create-namespace \
        --namespace my-fhir-release \
        --set database.dataStore=ExistingSqlServer \
        --set database.existingSqlServer.serverName="${SQL_SERVER_NAME}.database.windows.net" \
        --set database.existingSqlServer.databaseName=$SQL_SERVER_DB_NAME \
        --set database.existingSqlServer.userName=$SQL_SERVER_ADMIN_USER \
        --set database.existingSqlServer.password=$SQL_SERVER_ADMIN_PASSWD \
        --set podIdentity.enabled=true \
        --set podIdentity.identityClientId=$IDENT_CLIENT_ID \
        --set podIdentity.identityResourceId=$IDENT_RESOURCE_ID \
        --set export.enabled=true \
        --set export.blobStorageUri=$BLOB_STORAGE_URI
fi

# install cert-manager
if ! helm_release_exists cert-manager; then
    helm upgrade --install cert-manager jetstack/cert-manager \
      --create-namespace \
      --namespace cert-manager \
      --version $CERT_MANAGER_VERSION \
      --set installCRDs=true
fi

# create an Let's Encrypt Issuer
if ! k8s_resource_exists issuer letsencrypt-prod my-fhir-release; then
    log "Creating an Let's Encrypt Issuer..."
    envsubst < issuer-fhir.yml | kubectl apply -f -
fi

# install NGINX Ingress Controller
if ! helm_release_exists nginx-ingress; then
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
if ! k8s_resource_exists secret basic-auth default; then
    log "Creating an account for basic auth..."
    echo -n "Username: "
    read -r uname
    htpasswd -c auth $uname
    kubectl create secret generic basic-auth --from-file=auth
fi

# create a ingress route
if ! k8s_resource_exists ingress ingress-fhir my-fhir-release; then
    log "Creating a route to the FHIR server"
    envsubst < ingress-fhir.yml | kubectl apply -f -
fi
