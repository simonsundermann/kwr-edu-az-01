#!/usr/bin/env bash
set -euo pipefail

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1"; exit 1; }; }
need_cmd az
need_cmd gh

echo "==============================================="
echo " Azure → GitHub OIDC Setup (No SSH Keys needed)"
echo "==============================================="

# ---- Azure login (auto) ----
if ! az account show >/dev/null 2>&1; then
  echo "Azure CLI not logged in. Starting: az login"
  az login
fi

# ---- GitHub login (auto) ----
if ! gh auth status >/dev/null 2>&1; then
  echo "GitHub CLI not logged in. Starting: gh auth login"
  gh auth login
fi

# ---- Interactive inputs ----
read -rp "GitHub repository (owner/repo): " GITHUB_REPO
if ! [[ "$GITHUB_REPO" =~ ^[^/]+/[^/]+$ ]]; then
  echo "Invalid repo format. Must be owner/repo"
  exit 1
fi

read -rp "Service Principal name [sp-gh-oidc-terraform-gpu]: " SP_NAME
SP_NAME="${SP_NAME:-sp-gh-oidc-terraform-gpu}"

read -rp "Resource Group name [rg-gpu-robotics]: " RESOURCE_GROUP
RESOURCE_GROUP="${RESOURCE_GROUP:-rg-gpu-robotics}"

read -rp "Azure Location [westeurope]: " LOCATION
LOCATION="${LOCATION:-westeurope}"

read -rp "OIDC mode (branch/environment) [branch]: " OIDC_MODE
OIDC_MODE="${OIDC_MODE:-branch}"

if [[ "$OIDC_MODE" == "environment" ]]; then
  read -rp "GitHub Environment name [prod]: " OIDC_ENV
  OIDC_ENV="${OIDC_ENV:-prod}"
else
  read -rp "GitHub Branch [main]: " OIDC_BRANCH
  OIDC_BRANCH="${OIDC_BRANCH:-main}"
fi

read -rp "Set Entra VM login role for CURRENT user on RG? (y/N): " SET_VM_LOGIN
SET_VM_LOGIN="${SET_VM_LOGIN:-N}"

SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
TENANT_ID="$(az account show --query tenantId -o tsv)"
az account set --subscription "$SUBSCRIPTION_ID" >/dev/null

ORG="$(echo "$GITHUB_REPO" | cut -d/ -f1)"
REPO="$(echo "$GITHUB_REPO" | cut -d/ -f2)"

echo ""
echo "=== Configuration ==="
echo "Repo: $GITHUB_REPO"
echo "SP:   $SP_NAME"
echo "RG:   $RESOURCE_GROUP ($LOCATION)"
echo "Sub:  $SUBSCRIPTION_ID"
echo "OIDC: $OIDC_MODE"
echo "====================="

# ---- Ensure RG exists ----
if ! az group show -n "$RESOURCE_GROUP" >/dev/null 2>&1; then
  echo "Creating Resource Group..."
  az group create -n "$RESOURCE_GROUP" -l "$LOCATION" >/dev/null
fi
RG_ID="$(az group show -n "$RESOURCE_GROUP" --query id -o tsv)"

# ---- Create/reuse App ----
EXISTING_APP_ID="$(az ad app list --display-name "$SP_NAME" --query '[0].appId' -o tsv 2>/dev/null || true)"
if [[ -n "${EXISTING_APP_ID:-}" && "${EXISTING_APP_ID:-}" != "None" ]]; then
  APP_ID="$EXISTING_APP_ID"
  echo "Using existing App: $APP_ID"
else
  echo "Creating App Registration..."
  APP_ID="$(az ad app create --display-name "$SP_NAME" --query appId -o tsv)"
  echo "Created App: $APP_ID"
fi

SP_OBJECT_ID="$(az ad sp show --id "$APP_ID" --query id -o tsv 2>/dev/null || true)"
if [[ -z "${SP_OBJECT_ID:-}" || "${SP_OBJECT_ID:-}" == "None" ]]; then
  echo "Creating Service Principal..."
  SP_OBJECT_ID="$(az ad sp create --id "$APP_ID" --query id -o tsv)"
fi

# ---- RBAC: Contributor on RG ----
echo "Assigning SP Contributor on RG..."
az role assignment create \
  --assignee-object-id "$SP_OBJECT_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "Contributor" \
  --scope "$RG_ID" >/dev/null 2>&1 || true

# ---- Subscription Reader (needed for provider reads in many setups) ----
echo "Assigning SP Reader on subscription (safe, required often)..."
az role assignment create \
  --assignee-object-id "$SP_OBJECT_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "Reader" \
  --scope "/subscriptions/$SUBSCRIPTION_ID" >/dev/null 2>&1 || true

# ---- Federated Credential ----
if [[ "$OIDC_MODE" == "environment" ]]; then
  SUBJECT="repo:${ORG}/${REPO}:environment:${OIDC_ENV}"
  FIC_NAME="github-oidc-env-${OIDC_ENV}"
else
  SUBJECT="repo:${ORG}/${REPO}:ref:refs/heads/${OIDC_BRANCH}"
  FIC_NAME="github-oidc-branch-${OIDC_BRANCH}"
fi

tmpfile="$(mktemp)"
cat >"$tmpfile" <<EOF
{
  "name": "${FIC_NAME}",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "${SUBJECT}",
  "description": "GitHub Actions OIDC for ${ORG}/${REPO}",
  "audiences": ["api://AzureADTokenExchange"]
}
EOF

az ad app federated-credential create --id "$APP_ID" --parameters @"$tmpfile" >/dev/null 2>&1 || true
rm -f "$tmpfile"

# ---- GitHub Secrets (OIDC IDs only) ----
echo "Setting GitHub secrets..."
gh secret set AZURE_CLIENT_ID       --body "$APP_ID"          --repo "$GITHUB_REPO"
gh secret set AZURE_TENANT_ID       --body "$TENANT_ID"       --repo "$GITHUB_REPO"
gh secret set AZURE_SUBSCRIPTION_ID --body "$SUBSCRIPTION_ID" --repo "$GITHUB_REPO"

# Optional TF vars (no SSH key!)
gh secret set TF_VAR_admin_username --body "azureuser" --repo "$GITHUB_REPO"

# Remove legacy secrets
gh secret delete AZURE_CLIENT_SECRET --repo "$GITHUB_REPO" >/dev/null 2>&1 || true
gh secret delete AZURE_CREDENTIALS   --repo "$GITHUB_REPO" >/dev/null 2>&1 || true
gh secret delete TF_VAR_SSH_PUBLIC_KEY --repo "$GITHUB_REPO" >/dev/null 2>&1 || true

# ---- Optional: grant current user VM login role on RG ----
if [[ "$SET_VM_LOGIN" =~ ^[Yy]$ ]]; then
  echo "Granting current user 'Virtual Machine Administrator Login' on RG..."
  # This returns the signed-in user in many tenants; if it fails, do it manually.
  USER_OBJECT_ID="$(az ad signed-in-user show --query id -o tsv 2>/dev/null || true)"
  if [[ -z "${USER_OBJECT_ID:-}" || "${USER_OBJECT_ID:-}" == "None" ]]; then
    echo "WARN: Could not determine signed-in user object id. Assign role manually in Azure Portal or via az with --assignee."
  else
    az role assignment create \
      --assignee-object-id "$USER_OBJECT_ID" \
      --assignee-principal-type User \
      --role "Virtual Machine Administrator Login" \
      --scope "$RG_ID" >/dev/null 2>&1 || true
    echo "OK: Role assigned."
  fi
fi

echo ""
echo "DONE ✅"
echo "Next: run your GitHub workflow. After apply, use Terraform output bastion_aad_ssh_cmd for login."
