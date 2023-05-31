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

# deploy required Azure resources
log "Deploying required Azure resources"
az deployment sub create \
    --location $REGION_NAME \
    --template-file ./bicep/main.bicep \
    --parameters \
        k8s_version=$K8S_VERSION \
        rg_name=$RESOURCE_GROUP \
        vnet_range=$VNET_RANGE \
        subnet_range=$SUBNET_RANGE \
        sql_server_name=$SQL_SERVER_NAME \
        sql_server_db_name=$SQL_SERVER_DB_NAME \
        sql_server_admin_user=$SQL_SERVER_ADMIN_USER \
        sql_server_admin_passwd=$SQL_SERVER_ADMIN_PASSWD

# configure AKS credentials
log "Configuring AKS credentials..."
az aks get-credentials -g $RESOURCE_GROUP -n $AKS_CLUSTER_NAME
kubelogin convert-kubeconfig -l azurecli

# update helm repo list
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
        --create-namespace -n fhir-ns \
        --set database.dataStore=ExistingSqlServer \
        --set database.existingSqlServer.serverName="${SQL_SERVER_NAME}.database.windows.net" \
        --set database.existingSqlServer.databaseName=$SQL_SERVER_DB_NAME \
        --set database.existingSqlServer.userName=$SQL_SERVER_ADMIN_USER \
        --set database.existingSqlServer.password=$SQL_SERVER_ADMIN_PASSWD \
        --set podIdentity.enabled=true \
        --set podIdentity.identityClientId=$IDENT_CLIENT_ID \
        --set podIdentity.identityResourceId=$IDENT_RESOURCE_ID \
        --set export.enabled=true \
        --set export.blobStorageUri=$BLOB_STORAGE_URI \
        --set convertData.enabled=true
fi

# install cert-manager
if ! helm_release_exists cert-manager; then
    helm upgrade --install cert-manager jetstack/cert-manager \
      --create-namespace -n cert-mgr-ns \
      --version $CERT_MANAGER_VERSION \
      --set installCRDs=true
fi

# create an Let's Encrypt Issuer
if ! k8s_resource_exists issuer letsencrypt-prod fhir-ns; then
    log "Creating an Let's Encrypt Issuer..."
    envsubst < tmpl/issuer-fhir.yml | kubectl apply -f -
fi

# install NGINX Ingress Controller
if ! helm_release_exists nginx-ingress; then
    log "Installing NGINX Ingress Controller..."
    helm upgrade --install nginx-ingress ingress-nginx/ingress-nginx \
        --create-namespace -n ingress-ns \
        --set controller.replicaCount=2 \
        --set controller.nodeSelector."kubernetes\.io/os"=linux \
        --set defaultBackend.nodeSelector."kubernetes\.io/os"=linux \
        --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-load-balancer-health-probe-request-path"=/healthz \
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
if ! k8s_resource_exists ingress ingress-fhir fhir-ns; then
    log "Creating a route to the FHIR server"
    envsubst < tmpl/ingress-fhir.yml | kubectl apply -f -
fi
