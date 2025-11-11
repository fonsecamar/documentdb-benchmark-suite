#!/bin/bash

# setupAKS.sh - Deploy AKS cluster and benchmark workloads
# Usage: ./setupAKS.sh --resource-group <name> --location <location> [options]

set -e  # Exit on error

# Default values
RESOURCE_GROUP=""
LOCATION=""
AKS_NAME=""
STORAGE_ACCOUNT_NAME=""
ACR_NAME=""
SUFFIX=""
AKS_VM_SKU=""
SUBNET_ID=""

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --resource-group|-g)
            RESOURCE_GROUP="$2"
            shift 2
            ;;
        --location|-l)
            LOCATION="$2"
            shift 2
            ;;
        --aks-name)
            AKS_NAME="$2"
            shift 2
            ;;
        --storage-account-name)
            STORAGE_ACCOUNT_NAME="$2"
            shift 2
            ;;
        --acr-name)
            ACR_NAME="$2"
            shift 2
            ;;
        --suffix)
            SUFFIX="$2"
            shift 2
            ;;
        --aks-vm-sku)
            AKS_VM_SKU="$2"
            shift 2
            ;;
        --subnet-id)
            SUBNET_ID="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 --resource-group <name> --location <location> [options]"
            echo ""
            echo "Required parameters:"
            echo "  --resource-group, -g          Azure resource group name"
            echo "  --location, -l                Azure region (e.g., eastus, westeurope)"
            echo ""
            echo "Optional parameters:"
            echo "  --aks-name                    AKS cluster name"
            echo "  --storage-account-name        Storage account name"
            echo "  --acr-name                    Azure Container Registry name"
            echo "  --suffix                      Suffix for resource names"
            echo "  --aks-vm-sku                  VM SKU for AKS nodes"
            echo "  --subnet-id                   Existing subnet ID for AKS"
            echo "  --help, -h                    Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown parameter: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Validate required parameters
if [[ -z "$RESOURCE_GROUP" ]]; then
    echo "Error: --resource-group is required"
    echo "Use --help for usage information"
    exit 1
fi

if [[ -z "$LOCATION" ]]; then
    echo "Error: --location is required"
    echo "Use --help for usage information"
    exit 1
fi

# Change to script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

IMAGE_NAME="documentdbbenchmark:latest"

echo "==> Step 1: Creating resource group '$RESOURCE_GROUP' in '$LOCATION'..."
az group create --name "$RESOURCE_GROUP" --location "$LOCATION"

# Build Bicep parameters
BICEP_PARAMS="location=$LOCATION"
[[ -n "$SUFFIX" ]] && BICEP_PARAMS="$BICEP_PARAMS suffix=${SUFFIX,,}"
[[ -n "$AKS_NAME" ]] && BICEP_PARAMS="$BICEP_PARAMS aksName=${AKS_NAME,,}"
[[ -n "$STORAGE_ACCOUNT_NAME" ]] && BICEP_PARAMS="$BICEP_PARAMS storageAccountName=${STORAGE_ACCOUNT_NAME,,}"
[[ -n "$ACR_NAME" ]] && BICEP_PARAMS="$BICEP_PARAMS acrName=${ACR_NAME,,}"
[[ -n "$AKS_VM_SKU" ]] && BICEP_PARAMS="$BICEP_PARAMS aksVMSku=$AKS_VM_SKU"
[[ -n "$SUBNET_ID" ]] && BICEP_PARAMS="$BICEP_PARAMS existingSubnetId=$SUBNET_ID"

# 2. Deploy the Bicep template
echo "==> Step 2: Deploying Bicep template..."
BICEP_OUTPUT=$(az deployment group create \
    --resource-group "$RESOURCE_GROUP" \
    --template-file ../infra/deploy.bicep \
    --parameters $BICEP_PARAMS \
    --query "properties.outputs" -o json)

# Parse outputs
AKS_NAME=$(echo "$BICEP_OUTPUT" | jq -r '.aksName.value')
STORAGE_ACCOUNT_NAME=$(echo "$BICEP_OUTPUT" | jq -r '.storageAccountName.value')
SHARE_NAME=$(echo "$BICEP_OUTPUT" | jq -r '.shareName.value')
ACR_LOGIN=$(echo "$BICEP_OUTPUT" | jq -r '.acrLogin.value')

echo "  - AKS Name: $AKS_NAME"
echo "  - Storage Account: $STORAGE_ACCOUNT_NAME"
echo "  - File Share: $SHARE_NAME"
echo "  - ACR Login: $ACR_LOGIN"

# Get storage account key
echo "==> Step 3: Retrieving storage account key..."
ACCOUNT_KEY=$(az storage account keys list \
    --resource-group "$RESOURCE_GROUP" \
    --account-name "$STORAGE_ACCOUNT_NAME" \
    --query "[0].value" -o tsv)

# Upload configuration files
echo "==> Step 4: Uploading configuration files to Azure File Share..."
CONFIG_FOLDER="../config"
if [[ -d "$CONFIG_FOLDER" ]]; then
    for file in "$CONFIG_FOLDER"/*.{yaml,yml}; do
        if [[ -f "$file" ]]; then
            filename=$(basename "$file")
            echo "  - Uploading $filename..."
            az storage file upload \
                --account-name "$STORAGE_ACCOUNT_NAME" \
                --account-key "$ACCOUNT_KEY" \
                --share-name "$SHARE_NAME" \
                --path "$filename" \
                --source "$file" \
                --no-progress
        fi
    done
else
    echo "  Warning: Config folder not found at $CONFIG_FOLDER"
fi

# Get AKS credentials
echo "==> Step 5: Getting AKS credentials..."
az aks get-credentials \
    --resource-group "$RESOURCE_GROUP" \
    --name "$AKS_NAME" \
    --overwrite-existing

# Build and push Docker image
echo "==> Step 6: Building and pushing Docker image to ACR..."
az acr build \
    --registry "$ACR_LOGIN" \
    --image "$IMAGE_NAME" \
    ../src/.

# Create Kubernetes secret
echo "==> Step 7: Creating Kubernetes secret for Azure File Share..."
kubectl delete secret azure-file-secret --ignore-not-found
kubectl create secret generic azure-file-secret \
    --from-literal=azurestorageaccountname="$STORAGE_ACCOUNT_NAME" \
    --from-literal=azurestorageaccountkey="$ACCOUNT_KEY" \
    --type=Opaque

# Deploy Kubernetes resources
echo "==> Step 8: Deploying Kubernetes workloads..."

echo "  - Deploying master service..."
kubectl apply -f ./master-service.yaml

echo "  - Deploying config volume..."
sed -e "s/\${RESOURCE_GROUP}/$RESOURCE_GROUP/g" \
    -e "s/\${STORAGE_ACCOUNT}/$STORAGE_ACCOUNT_NAME/g" \
    -e "s/\${SHARE_NAME}/$SHARE_NAME/g" \
    ./config-volume.yaml | kubectl apply -f -

echo "  - Deploying master pod..."
sed "s|\${IMAGE_NAME}|$ACR_LOGIN/$IMAGE_NAME|g" \
    ./master-deployment.yaml | kubectl apply -f -

echo "  - Deploying worker pods..."
sed "s|\${IMAGE_NAME}|$ACR_LOGIN/$IMAGE_NAME|g" \
    ./worker-deployment.yaml | kubectl apply -f -

echo ""
echo "=========================================="
echo "Deployment complete!"
echo "=========================================="
echo "AKS cluster '$AKS_NAME' is ready and workloads are deployed."
echo ""
echo "Useful commands:"
echo "  kubectl get pods                    # Check pod status"
echo "  kubectl logs <pod-name>             # View pod logs"
echo "  kubectl get svc master-service      # Get master service details"
echo "=========================================="
