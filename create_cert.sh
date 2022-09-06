if [ ! -d auth ]; then
    mkdir auth
fi

cd auth

NEW_CA=false
if [ ! -f ca.key ] || [ ! -f ca.crt ]; then
    rm ca.key ca.crt 2>/dev/null || true

    log "Creating new ca.key and ca.crt..."
    openssl req -x509 -sha256 -newkey rsa:4096 -keyout ca.key -out ca.crt -days 356 -nodes -subj '/CN=My Cert Authority'

    NEW_CA=true
fi

if [ ! -f server.key ] || [ ! -f server.crt ] || $NEW_CA; then
    rm server.key server.csr server.crt 2>/dev/null || true
    SERVER_DOMAIN="${API_DNS_LABEL}.${REGION_NAME}.cloudapp.azure.com"

    log "Creating new server.key and server.crt..."
    openssl req -new -newkey rsa:4096 -keyout server.key -out server.csr -nodes -subj "/CN=${SERVER_DOMAIN}"
    openssl x509 -req -sha256 -days 365 -in server.csr -CA ca.crt -CAkey ca.key -set_serial 01 -out server.crt
fi

if [ ! -f client.key ] || [ ! -f client.crt ] || $NEW_CA; then
    rm client.key client.csr client.crt 2>/dev/null || true

    log "Creating new client.key and client.crt..."
    openssl req -new -newkey rsa:4096 -keyout client.key -out client.csr -nodes -subj '/CN=My Client'
    openssl x509 -req -sha256 -days 365 -in client.csr -CA ca.crt -CAkey ca.key -set_serial 02 -out client.crt
fi

if ! kubectl get secret ca-secret >/dev/null 2>&1; then
    log "Creating ca-secret..."
    kubectl create secret generic ca-secret --from-file=ca.crt=ca.crt
fi

if ! kubectl get secret tls-secret >/dev/null 2>&1; then
    log "Creating tls-secret..."
    kubectl create secret generic tls-secret --from-file=tls.crt=server.crt --from-file=tls.key=server.key
fi

cd ..
