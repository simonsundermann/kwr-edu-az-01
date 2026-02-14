# PowerShell Script: Create Service Principal for Terraform GPU VM Deployment
# This script creates an Azure service principal with permissions to create GPU VMs
# and adds GitHub secrets directly via GitHub CLI

param(
    [string]$ServicePrincipalName = "terraform-gpu-sp",
    [string]$SubscriptionId = "",
    [string]$GitHubRepo = "",
    [switch]$SkipGitHub
)

# Function to check if command exists
function Test-CommandExists {
    param([string]$command)
    $null = Get-Command $command -ErrorAction SilentlyContinue
    return $?
}

# Check prerequisites
Write-Host "Checking prerequisites..." -ForegroundColor Blue

if (-not (Test-CommandExists "az")) {
    Write-Host "✗ Azure CLI not found. Install from https://docs.microsoft.com/en-us/cli/azure/" -ForegroundColor Red
    exit 1
}

if (-not $SkipGitHub -and -not (Test-CommandExists "gh")) {
    Write-Host "✗ GitHub CLI not found. Install from https://cli.github.com/" -ForegroundColor Red
    Write-Host "  Or use -SkipGitHub flag to skip GitHub secret setup" -ForegroundColor Yellow
    exit 1
}

Write-Host "✓ Prerequisites check passed" -ForegroundColor Green

# Check if logged in to Azure
try {
    $account = az account show --query id -o tsv
    Write-Host "✓ Already logged in to Azure" -ForegroundColor Green
}
catch {
    Write-Host "✗ Not logged in. Running 'az login'..." -ForegroundColor Red
    az login
    if ($LASTEXITCODE -ne 0) {
        Write-Host "✗ Azure login failed" -ForegroundColor Red
        exit 1
    }
}

# Check GitHub authentication if not skipped
if (-not $SkipGitHub) {
    Write-Host "`nChecking GitHub authentication..." -ForegroundColor Blue
    $ghStatus = gh auth status 2>&1
    
    if ($LASTEXITCODE -ne 0) {
        Write-Host "✗ Not authenticated to GitHub. Logging in..." -ForegroundColor Yellow
        gh auth login
        
        if ($LASTEXITCODE -ne 0) {
            Write-Host "✗ GitHub authentication failed" -ForegroundColor Red
            exit 1
        }
    }
    Write-Host "✓ GitHub authenticated" -ForegroundColor Green
}

# Get GitHub repo if not skipping GitHub
if (-not $SkipGitHub) {
    if ([string]::IsNullOrEmpty($GitHubRepo)) {
        Write-Host "`nGetting current Git repository..." -ForegroundColor Blue
        try {
            $GitHubRepo = git config --get remote.origin.url
            if ($GitHubRepo -match "github.com[:/](.+)/(.+?)(?:.git)?$") {
                $GitHubRepo = "$($matches[1])/$($matches[2])" -replace "\.git$", ""
                Write-Host "Found GitHub repo: $GitHubRepo" -ForegroundColor Green
            }
            else {
                Write-Host "Could not parse GitHub repo from git remote" -ForegroundColor Yellow
                $GitHubRepo = Read-Host "Enter GitHub repository (owner/repo)"
            }
        }
        catch {
            Write-Host "Could not get git remote. Please provide GitHub repo manually" -ForegroundColor Yellow
            $GitHubRepo = Read-Host "Enter GitHub repository (owner/repo)"
        }
    }
}

# Get subscription ID if not provided
if ([string]::IsNullOrEmpty($SubscriptionId)) {
    $SubscriptionId = az account show --query id -o tsv
}

Write-Host "Using subscription: $SubscriptionId" -ForegroundColor Blue

# Check if service principal already exists
$existingSp = az ad sp list --display-name $ServicePrincipalName --query "[0].appId" -o tsv 2>$null

if ($existingSp -and $existingSp -ne "None") {
    Write-Host "⚠ Service principal '$ServicePrincipalName' already exists" -ForegroundColor Yellow
    $AppId = $existingSp
}
else {
    Write-Host "Creating service principal: $ServicePrincipalName..." -ForegroundColor Blue
    
    $sp = az ad sp create-for-rbac `
        --name $ServicePrincipalName `
        --role "Contributor" `
        --scopes "/subscriptions/$SubscriptionId" `
        --years 2 | ConvertFrom-Json
    
    $AppId = $sp.appId
    $ClientSecret = $sp.password
    
    Write-Host "✓ Service principal created" -ForegroundColor Green
    Write-Host "App ID: $AppId" -ForegroundColor Green
}

# Get tenant ID
$TenantId = az account show --query tenantId -o tsv

Write-Host "`n========================================" -ForegroundColor Blue
Write-Host "Azure Credentials" -ForegroundColor Green
Write-Host "========================================`n" -ForegroundColor Blue

Write-Host "AZURE_CLIENT_ID: $AppId" -ForegroundColor Cyan
Write-Host "AZURE_TENANT_ID: $TenantId" -ForegroundColor Cyan
Write-Host "AZURE_SUBSCRIPTION_ID: $SubscriptionId" -ForegroundColor Cyan

if ($ClientSecret) {
    Write-Host "AZURE_CLIENT_SECRET: $ClientSecret" -ForegroundColor Yellow
    Write-Host "⚠️  Save this secret securely - it will not be displayed again!" -ForegroundColor Red
}

# Add secrets to GitHub if not skipped
if (-not $SkipGitHub) {
    Write-Host "`n========================================" -ForegroundColor Blue
    Write-Host "Adding secrets to GitHub repository" -ForegroundColor Green
    Write-Host "========================================`n" -ForegroundColor Blue
    
    Write-Host "Repository: $GitHubRepo`n" -ForegroundColor Cyan
    
    try {
        Write-Host "Adding AZURE_CLIENT_ID..." -ForegroundColor Yellow
        gh secret set AZURE_CLIENT_ID --body "$AppId" --repo $GitHubRepo
        if ($LASTEXITCODE -eq 0) {
            Write-Host "✓ AZURE_CLIENT_ID added" -ForegroundColor Green
        }
        
        Write-Host "Adding AZURE_TENANT_ID..." -ForegroundColor Yellow
        gh secret set AZURE_TENANT_ID --body "$TenantId" --repo $GitHubRepo
        if ($LASTEXITCODE -eq 0) {
            Write-Host "✓ AZURE_TENANT_ID added" -ForegroundColor Green
        }
        
        Write-Host "Adding AZURE_SUBSCRIPTION_ID..." -ForegroundColor Yellow
        gh secret set AZURE_SUBSCRIPTION_ID --body "$SubscriptionId" --repo $GitHubRepo
        if ($LASTEXITCODE -eq 0) {
            Write-Host "✓ AZURE_SUBSCRIPTION_ID added" -ForegroundColor Green
        }
        
        if ($ClientSecret) {
            Write-Host "Adding AZURE_CLIENT_SECRET..." -ForegroundColor Yellow
            gh secret set AZURE_CLIENT_SECRET --body "$ClientSecret" --repo $GitHubRepo
            if ($LASTEXITCODE -eq 0) {
                Write-Host "✓ AZURE_CLIENT_SECRET added" -ForegroundColor Green
            }
        }
        
        Write-Host "`n✓ All secrets added to GitHub successfully!" -ForegroundColor Green
    }
    catch {
        Write-Host "✗ Error adding secrets to GitHub: $_" -ForegroundColor Red
        Write-Host "Please add them manually via GitHub UI" -ForegroundColor Yellow
    }
}

Write-Host "`n========================================" -ForegroundColor Blue
Write-Host "Setup Complete!" -ForegroundColor Green
Write-Host "========================================`n" -ForegroundColor Blue

if (-not $SkipGitHub) {
    Write-Host "✓ Service principal created" -ForegroundColor Green
    Write-Host "✓ GitHub secrets configured" -ForegroundColor Green
    Write-Host "`nYour GitHub Actions workflow can now authenticate with Azure!" -ForegroundColor Cyan
    Write-Host "Secrets are ready in: $GitHubRepo" -ForegroundColor Cyan
}
else {
    Write-Host "✓ Service principal created" -ForegroundColor Green
    Write-Host "`nTo add secrets to GitHub manually:" -ForegroundColor Yellow
    Write-Host "  gh secret set AZURE_CLIENT_ID --body '$AppId' --repo <owner/repo>" -ForegroundColor Gray
    Write-Host "  gh secret set AZURE_TENANT_ID --body '$TenantId' --repo <owner/repo>" -ForegroundColor Gray
    Write-Host "  gh secret set AZURE_SUBSCRIPTION_ID --body '$SubscriptionId' --repo <owner/repo>" -ForegroundColor Gray
    if ($ClientSecret) {
        Write-Host "  gh secret set AZURE_CLIENT_SECRET --body '<secret>' --repo <owner/repo>" -ForegroundColor Gray
    }
}

Write-Host "`nEnvironment variables for local Terraform testing:" -ForegroundColor Yellow
Write-Host "`$env:ARM_CLIENT_ID = '$AppId'" -ForegroundColor Gray
Write-Host "`$env:ARM_CLIENT_SECRET = '<your-secret>'" -ForegroundColor Gray
Write-Host "`$env:ARM_TENANT_ID = '$TenantId'" -ForegroundColor Gray
Write-Host "`$env:ARM_SUBSCRIPTION_ID = '$SubscriptionId'" -ForegroundColor Gray
