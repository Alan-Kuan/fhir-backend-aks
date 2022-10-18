log() {
    echo "[SETUP] $1"
}

az_resource_exists() {
    local rsc_group=$1
    local rsc_name=$2
    shift 2
    local rsc_type=$@
    az $rsc_type show -g $rsc_group -n $rsc_name --output none 2>/dev/null
}

helm_release_exists() {
    local release_name=$1
    local info=`helm list -A -f $release_name -o json -q 2>/dev/null`
    [ ! -z "$info" ] && [ `echo $info | jq '. | length'` -gt 0 ]
}

k8s_resource_exists() {
    local kind=$1
    local name=$2
    local namespace=$3
    kubectl get $kind $name -n $namespace >/dev/null 2>&1
}
