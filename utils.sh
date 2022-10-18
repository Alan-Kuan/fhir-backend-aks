# $1: msg
log() {
    echo "[SETUP] $1"
}

# $1: release name
helm_release_exists() {
    INFO=`helm list -A -f "$1" -o json -q 2>/dev/null`
    [ ! -z "$INFO" ] && [ `echo $INFO | jq '. | length'` -gt 0 ]
}
