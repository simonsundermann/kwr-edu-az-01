#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./register-providers.sh
#   ./register-providers.sh <subscription_id>

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1"; exit 1; }; }
need_cmd az

echo "=============================================="
echo " Azure Provider Registration (Secure Minimal)"
echo "=============================================="

# ---------------------------------------
# Azure Login Check
# ---------------------------------------
if ! az account show >/dev/null 2>&1; then
  echo "Azure CLI not logged in. Starting login..."
  az login
fi

# ---------------------------------------
# Determine Subscription
# ---------------------------------------
SUBSCRIPTION_ID="${1:-}"

if [[ -z "$SUBSCRIPTION_ID" ]]; then
  SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
  echo "Using default subscription: $SUBSCRIPTION_ID"
else
  echo "Using provided subscription: $SUBSCRIPTION_ID"
fi

az account set --subscription "$SUBSCRIPTION_ID"

TENANT_ID="$(az account show --query tenantId -o tsv)"
echo "Tenant: $TENANT_ID"

# ---------------------------------------
# Required Providers for your GPU setup
# ---------------------------------------
PROVIDERS=(
  "Microsoft.Compute"
  "Microsoft.Network"
  "Microsoft.Storage"
  "Microsoft.ManagedIdentity"
  "Microsoft.Management"
  "Microsoft.Web"
)

echo ""
echo "Checking and registering required providers..."

for PROVIDER in "${PROVIDERS[@]}"; do
  STATE=$(az provider show \
           --namespace "$PROVIDER" \
           --query registrationState \
           -o tsv 2>/dev/null || echo "NotRegistered")

  if [[ "$STATE" == "Registered" ]]; then
    echo "✔ $PROVIDER already registered."
  else
    echo "→ Registering $PROVIDER ..."
    az provider register --namespace "$PROVIDER" >/dev/null
  fi
done

echo ""
echo "Waiting for providers to finish registering..."

for PROVIDER in "${PROVIDERS[@]}"; do
  while true; do
    STATE=$(az provider show \
             --namespace "$PROVIDER" \
             --query registrationState \
             -o tsv)

    if [[ "$STATE" == "Registered" ]]; then
      echo "✔ $PROVIDER is registered."
      break
    else
      echo "  $PROVIDER state: $STATE ... waiting"
      sleep 5
    fi
  done
done

echo ""
echo "=============================================="
echo " All required providers registered successfully"
echo "=============================================="
