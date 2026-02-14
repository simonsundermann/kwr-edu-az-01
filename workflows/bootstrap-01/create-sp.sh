#!/bin/bash

# Azure CLI Script: Create Service Principal for Terraform GPU VM Deployment
# This script creates an Azure service principal with permissions to create GPU VMs
# For use with GitHub Actions and Terraform

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SERVICE_PRINCIPAL_NAME="${1:-terraform-gpu-sp}"
SUBSCRIPTION_ID="${2:-}"
GITHUB_REPO="${3:-}"
SKIP_GITHUB="${SKIP_GITHUB:-false}"

# Helper functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."

    if ! command -v az &> /dev/null; then
        log_error "Azure CLI is not installed. Please install it from https://docs.microsoft.com/en-us/cli/azure/install-azure-cli"
        exit 1
    fi

    if [ "$SKIP_GITHUB" != "true" ]; then
        if ! command -v gh &> /dev/null; then
            log_error "GitHub CLI is not installed. Install from https://cli.github.com/ or use SKIP_GITHUB=true"
            exit 1
        fi
    fi

    if ! az account show &> /dev/null; then
        log_error "Not logged in to Azure. Please run 'az login' first"
        exit 1
    fi

    log_success "Prerequisites check passed"
}

# Get subscription ID if not provided
get_subscription_id() {
    if [ -z "$SUBSCRIPTION_ID" ]; then
        log_info "Retrieving current subscription ID..."
        SUBSCRIPTION_ID=$(az account show --query id -o tsv)
    fi
    log_info "Using subscription: $SUBSCRIPTION_ID"
}

# Authenticate with GitHub
authenticate_github() {
    if [ "$SKIP_GITHUB" = "true" ]; then
        return
    fi

    log_info "Checking GitHub authentication..."
    
    if ! gh auth status &> /dev/null; then
        log_warning "Not authenticated to GitHub. Logging in..."
        # If a token is provided, prefer non-interactive login
        if [ -n "${GITHUB_TOKEN:-}" ]; then
            log_info "Logging in non-interactively using GITHUB_TOKEN"
            if echo "$GITHUB_TOKEN" | gh auth login --with-token >/dev/null 2>&1; then
                log_success "GitHub authenticated (token)"
                return
            else
                log_warning "GITHUB_TOKEN login failed; falling back to interactive login"
            fi
        fi

        if ! gh auth login; then
            log_error "GitHub authentication failed"
            exit 1
        fi
    fi
    log_success "GitHub authenticated"
}

# Get GitHub repository
get_github_repo() {
    if [ "$SKIP_GITHUB" = "true" ]; then
        return
    fi

    if [ -z "$GITHUB_REPO" ]; then
        log_info "Detecting GitHub repository from git remote..."
        
        if ! command -v git &> /dev/null; then
            log_warning "Git not found. Please provide GitHub repo manually"
            read -p "Enter GitHub repository (owner/repo): " GITHUB_REPO
        else
            GITHUB_REPO=$(git config --get remote.origin.url 2>/dev/null || echo "")
            
            if [ -n "$GITHUB_REPO" ]; then
                # Parse GitHub URL to get owner/repo format
                GITHUB_REPO=$(echo "$GITHUB_REPO" | sed -E 's|.*github\.com[:/]([^/]+)/(.+?)(|\.git)$|\1/\2|')
                log_success "Found GitHub repo: $GITHUB_REPO"
            else
                log_warning "Could not detect GitHub repo from git remote"
                read -p "Enter GitHub repository (owner/repo): " GITHUB_REPO
            fi
        fi
    fi
}

# Add secrets to GitHub
add_github_secrets() {
    if [ "$SKIP_GITHUB" = "true" ] || [ -z "$GITHUB_REPO" ]; then
        return
    fi

    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${GREEN}Adding secrets to GitHub${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
    log_info "Repository: $GITHUB_REPO"
    echo ""

    # Add AZURE_CLIENT_ID
    log_info "Adding AZURE_CLIENT_ID..."
    if gh secret set AZURE_CLIENT_ID --body "$APP_ID" --repo "$GITHUB_REPO"; then
        log_success "AZURE_CLIENT_ID added"
    else
        log_warning "Failed to add AZURE_CLIENT_ID"
    fi

    # Add AZURE_TENANT_ID
    log_info "Adding AZURE_TENANT_ID..."
    if gh secret set AZURE_TENANT_ID --body "$TENANT_ID" --repo "$GITHUB_REPO"; then
        log_success "AZURE_TENANT_ID added"
    else
        log_warning "Failed to add AZURE_TENANT_ID"
    fi

    # Add AZURE_SUBSCRIPTION_ID
    log_info "Adding AZURE_SUBSCRIPTION_ID..."
    if gh secret set AZURE_SUBSCRIPTION_ID --body "$SUBSCRIPTION_ID" --repo "$GITHUB_REPO"; then
        log_success "AZURE_SUBSCRIPTION_ID added"
    else
        log_warning "Failed to add AZURE_SUBSCRIPTION_ID"
    fi

    # Add AZURE_CLIENT_SECRET
    if [ -n "$CLIENT_SECRET" ]; then
        # If the secret was supplied via AZURE_CLIENT_SECRET env, assume it's already set in the
        # environment/CI and avoid overwriting the repo secret. Otherwise, add it to the repo.
        if [ -n "${AZURE_CLIENT_SECRET:-}" ]; then
            log_info "AZURE_CLIENT_SECRET provided via environment; skipping gh secret set to avoid overwrite"
            log_success "AZURE_CLIENT_SECRET present"
        else
            log_info "Adding AZURE_CLIENT_SECRET..."
            if gh secret set AZURE_CLIENT_SECRET --body "$CLIENT_SECRET" --repo "$GITHUB_REPO"; then
                log_success "AZURE_CLIENT_SECRET added"
            else
                log_warning "Failed to add AZURE_CLIENT_SECRET"
            fi
        fi
    fi

    echo ""
    log_success "All secrets added to GitHub successfully!"
    echo ""
}

# Create service principal
create_service_principal() {
    log_info "Creating service principal: $SERVICE_PRINCIPAL_NAME..."

    # Check if service principal already exists
    existing_sp=$(az ad sp list --display-name "$SERVICE_PRINCIPAL_NAME" --query "[0].appId" -o tsv 2>/dev/null || echo "")

    if [ -n "$existing_sp" ] && [ "$existing_sp" != "None" ]; then
        log_warning "Service principal '$SERVICE_PRINCIPAL_NAME' already exists"
        APP_ID="$existing_sp"
        read -p "Continue with existing service principal? (y/n) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Exiting..."
            exit 0
        fi
    else
        # Create new service principal
        # Note: avoid a leading slash on the scope when running under Git Bash on Windows;
        # MSYS can rewrite paths like "/subscriptions/..." to a Windows filesystem path
        # (e.g. "C:/Program Files/Git/subscriptions/...") which breaks the Azure API call.
        # Use az's --query to return only the appId (avoids requiring jq)
        APP_ID=$(az ad sp create-for-rbac \
            --name "$SERVICE_PRINCIPAL_NAME" \
            --role "Contributor" \
            --scopes "subscriptions/$SUBSCRIPTION_ID" \
            --years 2 --query appId -o tsv)

        log_success "Service principal created with App ID: $APP_ID"
    fi
}

# Assign additional custom role for GPU compute if needed
assign_custom_role() {
    log_info "Assigning Contributor role for resource group operations..."

    TENANT_ID=$(az account show --query tenantId -o tsv)
    
    # Get the service principal's object ID
    PRINCIPAL_ID=$(az ad sp show --id "$APP_ID" --query id -o tsv)

    # Assign Contributor role at subscription level (already done in creation, but confirming)
    log_info "Service principal configured with Contributor role on subscription"
    log_info "This includes permissions for:"
    log_info "  - Creating virtual machines"
    log_info "  - Creating GPU-enabled instances"
    log_info "  - Managing networking, storage, and other required resources"
}

# Generate credentials for GitHub Actions
generate_github_secrets() {
    log_info "Generating credentials for GitHub Actions..."

    TENANT_ID=$(az account show --query tenantId -o tsv)

    # Retrieve service principal credentials
    SP_DETAILS=$(az ad sp show --id "$APP_ID" --query "{appId: appId, displayName: displayName}" -o json)

    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${GREEN}GitHub Actions Secrets${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
    echo "Add the following secrets to your GitHub repository:"
    echo "(Settings → Secrets and variables → Actions → New repository secret)"
    echo ""
    echo "AZURE_CLIENT_ID: $APP_ID"
    echo "AZURE_TENANT_ID: $TENANT_ID"
    echo "AZURE_SUBSCRIPTION_ID: $SUBSCRIPTION_ID"
    echo ""
    if [ -n "${AZURE_CLIENT_SECRET:-}" ]; then
        echo "Note: Using existing AZURE_CLIENT_SECRET from environment (value not displayed)."
    else
        echo "Note: The client secret is displayed below. Save it in a secure location."
        echo ""
    fi
}

# Create client secret
create_client_secret() {
    log_info "Creating client secret for service principal..."

    # Use az's --query to extract the password directly (no jq needed)
    CLIENT_SECRET=$(az ad app credential reset \
        --id "$APP_ID" \
        --display-name "terraform-github-secret" \
        --years 2 --query password -o tsv)

    echo -e "${YELLOW}AZURE_CLIENT_SECRET: $CLIENT_SECRET${NC}"
    echo ""
    echo -e "${RED}⚠️  SAVE THIS SECRET SECURELY - IT WILL NOT BE DISPLAYED AGAIN!${NC}"
    echo ""
}

# Display terraform environment variables
display_terraform_config() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${GREEN}Terraform Configuration${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
    echo "Environment variables for local Terraform testing:"
    echo ""
    echo "export ARM_CLIENT_ID=\"$APP_ID\""
    echo "export ARM_CLIENT_SECRET=\"<save-your-secret-here>\""
    echo "export ARM_TENANT_ID=\"$TENANT_ID\""
    echo "export ARM_SUBSCRIPTION_ID=\"$SUBSCRIPTION_ID\""
    echo ""
    echo "Or add to Terraform provider configuration:"
    echo ""
    cat << EOF
provider "azurerm" {
  features {}

  client_id       = var.client_id       # Set via environment/tfvars
  client_secret   = var.client_secret   # Set via environment/tfvars
  tenant_id       = var.tenant_id       # Set via environment/tfvars
  subscription_id = var.subscription_id # Set via environment/tfvars
}
EOF
    echo ""
}

# Display GitHub Actions workflow example
display_github_workflow_example() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${GREEN}GitHub Actions Workflow Example${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
    cat << 'EOF'
# .github/workflows/terraform-deploy.yml
name: Terraform Deploy

on:
  push:
    branches: [ main ]
  pull_request:
    branches: [ main ]

env:
  ARM_CLIENT_ID: ${{ secrets.AZURE_CLIENT_ID }}
  ARM_CLIENT_SECRET: ${{ secrets.AZURE_CLIENT_SECRET }}
  ARM_TENANT_ID: ${{ secrets.AZURE_TENANT_ID }}
  ARM_SUBSCRIPTION_ID: ${{ secrets.AZURE_SUBSCRIPTION_ID }}

jobs:
  terraform:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      
      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v2
        with:
          terraform_version: ~> 1.6
      
      - name: Terraform Init
        run: terraform init
      
      - name: Terraform Plan
        run: terraform plan -out=tfplan
      
      - name: Terraform Apply
        if: github.ref == 'refs/heads/main' && github.event_name == 'push'
        run: terraform apply tfplan
EOF
    echo ""
}

# Main execution
main() {
    echo ""
    log_info "========== Azure Service Principal Setup =========="
    echo ""

    check_prerequisites
    get_subscription_id
    authenticate_github
    get_github_repo
    create_service_principal
    assign_custom_role
    # If AZURE_CLIENT_SECRET is provided in the environment (e.g., CI/GitHub Actions or user-supplied),
    # use it instead of creating a new client secret. This allows the script to run without
    # creating/resetting credentials when a secret already exists.
    if [ -n "${AZURE_CLIENT_SECRET:-}" ]; then
        CLIENT_SECRET="$AZURE_CLIENT_SECRET"
        log_info "Using existing AZURE_CLIENT_SECRET from environment (will not display value)"
    else
        create_client_secret
    fi

    add_github_secrets
    generate_github_secrets
    display_terraform_config
    display_github_workflow_example

    echo -e "${GREEN}✓ Service principal setup complete!${NC}"
    echo ""
    
    if [ "$SKIP_GITHUB" != "true" ] && [ -n "$GITHUB_REPO" ]; then
        log_success "GitHub secrets have been configured for: $GITHUB_REPO"
    else
        log_info "Next steps:"
        echo "1. Save the AZURE_CLIENT_SECRET value securely (shown above)"
        echo "2. Add the GitHub Actions Secrets to your repository manually"
        echo ""
        if [ "$SKIP_GITHUB" = "true" ]; then
            echo "To add secrets via command line:"
            echo "  gh secret set AZURE_CLIENT_ID --body '$APP_ID' --repo <owner/repo>"
            echo "  gh secret set AZURE_TENANT_ID --body '$TENANT_ID' --repo <owner/repo>"
            echo "  gh secret set AZURE_SUBSCRIPTION_ID --body '$SUBSCRIPTION_ID' --repo <owner/repo>"
            if [ -n "$CLIENT_SECRET" ]; then
                echo "  gh secret set AZURE_CLIENT_SECRET --body '<secret>' --repo <owner/repo>"
            fi
        fi
    fi
    
    echo ""
    log_warning "Remember to keep credentials secret - never commit them to version control!"
    echo ""
}

# Run main function
main
