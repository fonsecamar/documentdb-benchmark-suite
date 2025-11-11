<#
.SYNOPSIS
    Deploy AKS cluster and benchmark workloads

.DESCRIPTION
    This script automates the deployment of an AKS cluster with Azure Container Registry,
    Azure File Share for configuration storage, and deploys the benchmark application.

.PARAMETER ResourceGroupName
    Azure resource group name (required)

.PARAMETER Location
    Azure region (e.g., eastus, westeurope) (required)

.PARAMETER AksName
    AKS cluster name (optional, auto-generated if not provided)

.PARAMETER StorageAccountName
    Storage account name (optional, auto-generated if not provided)

.PARAMETER AcrName
    Azure Container Registry name (optional, auto-generated if not provided)

.PARAMETER Suffix
    Suffix for resource names (optional)

.PARAMETER AksVMSku
    VM SKU for AKS nodes (optional, defaults to Standard_D2s_v3)

.PARAMETER SubnetId
    Existing subnet ID for AKS (optional)

.EXAMPLE
    .\setupAKS.ps1 -ResourceGroupName "myRG" -Location "eastus"

.EXAMPLE
    .\setupAKS.ps1 -ResourceGroupName "myRG" -Location "eastus" -Suffix "prod" -AksVMSku "Standard_D4s_v3"
#>

param(
    [Parameter(Mandatory = $true, HelpMessage = "Azure resource group name")]
    [string]$ResourceGroupName,
    
    [Parameter(Mandatory = $true, HelpMessage = "Azure region (e.g., eastus, westeurope)")]
    [string]$Location,
    
    [Parameter(Mandatory = $false, HelpMessage = "AKS cluster name")]
    [string]$AksName = $null,
    
    [Parameter(Mandatory = $false, HelpMessage = "Storage account name")]
    [string]$StorageAccountName = $null,
    
    [Parameter(Mandatory = $false, HelpMessage = "Azure Container Registry name")]
    [string]$AcrName = $null,
    
    [Parameter(Mandatory = $false, HelpMessage = "Suffix for resource names")]
    [string]$Suffix = $null,
    
    [Parameter(Mandatory = $false, HelpMessage = "VM SKU for AKS nodes")]
    [string]$AksVMSku = $null,
    
    [Parameter(Mandatory = $false, HelpMessage = "Existing subnet ID for AKS")]
    [string]$SubnetId = $null
)

# Exit on error
$ErrorActionPreference = "Stop"

Push-Location $PSScriptRoot

$ImageName = "documentdbbenchmark:latest"

Write-Host "=========================================="
Write-Host "AKS Cluster Deployment Script"
Write-Host "=========================================="
Write-Host ""

# Step 1: Create the resource group
Write-Host "==> Step 1: Creating resource group '$ResourceGroupName' in '$Location'..." -ForegroundColor Cyan
az group create --name $ResourceGroupName --location $Location
if ($LASTEXITCODE -ne 0) {
    throw "Failed to create resource group"
}

# Build Bicep parameters
Write-Host ""
Write-Host "==> Step 2: Deploying Bicep template..." -ForegroundColor Cyan
$paramArgs = @("location=$Location")
if ($Suffix) { $paramArgs += "suffix=$($Suffix.ToLower())" }
if ($AksName) { $paramArgs += "aksName=$($AksName.ToLower())" }
if ($StorageAccountName) { $paramArgs += "storageAccountName=$($StorageAccountName.ToLower())" }
if ($AcrName) { $paramArgs += "acrName=$($AcrName.ToLower())" }
if ($AksVMSku) { $paramArgs += "aksVMSku=$AksVMSku" }
if ($SubnetId) { $paramArgs += "existingSubnetId=$SubnetId" }

$bicepOutput = az deployment group create `
    --resource-group $ResourceGroupName `
    --template-file ../infra/deploy.bicep `
    --parameters $paramArgs `
    --query "properties.outputs" -o json | ConvertFrom-Json

if ($LASTEXITCODE -ne 0) {
    throw "Failed to deploy Bicep template"
}

# Parse outputs
$AksName = $bicepOutput.aksName.value
$StorageAccountName = $bicepOutput.storageAccountName.value
$ShareName = $bicepOutput.shareName.value
$AcrLogin = $bicepOutput.acrLogin.value

Write-Host "  - AKS Name: $AksName" -ForegroundColor Gray
Write-Host "  - Storage Account: $StorageAccountName" -ForegroundColor Gray
Write-Host "  - File Share: $ShareName" -ForegroundColor Gray
Write-Host "  - ACR Login: $AcrLogin" -ForegroundColor Gray

# Get storage account key
Write-Host ""
Write-Host "==> Step 3: Retrieving storage account key..." -ForegroundColor Cyan
$AccountKey = az storage account keys list `
    --resource-group $ResourceGroupName `
    --account-name $StorageAccountName `
    --query "[0].value" -o tsv

if ($LASTEXITCODE -ne 0) {
    throw "Failed to retrieve storage account key"
}

# Upload configuration files
Write-Host ""
Write-Host "==> Step 4: Uploading configuration files to Azure File Share..." -ForegroundColor Cyan
$ConfigFolder = "../config"
if (Test-Path $ConfigFolder) {
    $YamlFiles = Get-ChildItem -Path "$ConfigFolder/*" -Include *.yaml,*.yml -File
    
    if ($YamlFiles.Count -eq 0) {
        Write-Host "  Warning: No YAML files found in $ConfigFolder" -ForegroundColor Yellow
    } else {
        foreach ($file in $YamlFiles) {
            Write-Host "  - Uploading $($file.Name)..." -ForegroundColor Gray
            az storage file upload `
                --account-name $StorageAccountName `
                --account-key $AccountKey `
                --share-name $ShareName `
                --path $file.Name `
                --source $file.FullName `
                --no-progress
            
            if ($LASTEXITCODE -ne 0) {
                Write-Host "  Warning: Failed to upload $($file.Name)" -ForegroundColor Yellow
            }
        }
    }
} else {
    Write-Host "  Warning: Config folder not found at $ConfigFolder" -ForegroundColor Yellow
}

# Get AKS credentials
Write-Host ""
Write-Host "==> Step 5: Getting AKS credentials..." -ForegroundColor Cyan
az aks get-credentials --resource-group $ResourceGroupName --name $AksName --overwrite-existing
if ($LASTEXITCODE -ne 0) {
    throw "Failed to get AKS credentials"
}

# Build and push Docker image
Write-Host ""
Write-Host "==> Step 6: Building and pushing Docker image to ACR..." -ForegroundColor Cyan
az acr build --registry $AcrLogin --image $ImageName ../src/.
if ($LASTEXITCODE -ne 0) {
    throw "Failed to build and push Docker image"
}

# Create Kubernetes secret
Write-Host ""
Write-Host "==> Step 7: Creating Kubernetes secret for Azure File Share..." -ForegroundColor Cyan
kubectl delete secret azure-file-secret --ignore-not-found
kubectl create secret generic azure-file-secret `
    --from-literal=azurestorageaccountname=$StorageAccountName `
    --from-literal=azurestorageaccountkey=$AccountKey `
    --type=Opaque

if ($LASTEXITCODE -ne 0) {
    throw "Failed to create Kubernetes secret"
}

# Deploy Kubernetes resources
Write-Host ""
Write-Host "==> Step 8: Deploying Kubernetes workloads..." -ForegroundColor Cyan

Write-Host "  - Deploying master service..." -ForegroundColor Gray
kubectl apply -f ./master-service.yaml
if ($LASTEXITCODE -ne 0) {
    throw "Failed to deploy master service"
}

Write-Host "  - Deploying config volume..." -ForegroundColor Gray
(Get-Content ./config-volume.yaml) `
    -replace '\$\{RESOURCE_GROUP\}', $ResourceGroupName `
    -replace '\$\{STORAGE_ACCOUNT\}', $StorageAccountName `
    -replace '\$\{SHARE_NAME\}', $ShareName | `
kubectl apply -f -

if ($LASTEXITCODE -ne 0) {
    throw "Failed to deploy config volume"
}

Write-Host "  - Deploying master pod..." -ForegroundColor Gray
(Get-Content ./master-deployment.yaml) `
    -replace '\$\{IMAGE_NAME\}', "$AcrLogin/$ImageName" | `
kubectl apply -f -

if ($LASTEXITCODE -ne 0) {
    throw "Failed to deploy master pod"
}

Write-Host "  - Deploying worker pods..." -ForegroundColor Gray
(Get-Content ./worker-deployment.yaml) `
    -replace '\$\{IMAGE_NAME\}', "$AcrLogin/$ImageName" | `
kubectl apply -f -

if ($LASTEXITCODE -ne 0) {
    throw "Failed to deploy worker pods"
}

Pop-Location

Write-Host ""
Write-Host "==========================================" -ForegroundColor Green
Write-Host "Deployment complete!" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green
Write-Host "AKS cluster '$AksName' is ready and workloads are deployed."
Write-Host ""
Write-Host "Useful commands:" -ForegroundColor Cyan
Write-Host "  kubectl get pods                    # Check pod status"
Write-Host "  kubectl logs <pod-name>             # View pod logs"
Write-Host "  kubectl get svc master-service      # Get master service details"
Write-Host "==========================================" -ForegroundColor Green