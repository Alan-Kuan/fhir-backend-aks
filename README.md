# fhir-backend-aks
Scripts to deploy Microsoft FHIR Server on AKS

## Required Commands
- az
- helm
- kubectl
- kubelogin
- jq
- htpasswd

## Usage
1. Copy `env.example.sh` into `env.sh` and fill in your values.
    - If you run the script before creating `env.sh`, the script will remind you.
3. Run `setup.sh`.
    ```sh
    ./setup.sh
    ```

## Comparison of `setup.sh` and `setup.sh.old`
To deploy Azure resources, `setup.sh.old` provisions them *imperatively* with Azure CLI.
In contrast, the newer script, `setup.sh`, provisions *declartively* with Azure Bicep, which is an IaC language designed for Azure
