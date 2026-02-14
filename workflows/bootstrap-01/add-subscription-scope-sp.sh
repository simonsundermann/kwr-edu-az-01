APP_ID="90e055af-611f-42bf-8175-d995ab371c8a"
SUBSCRIPTION_ID="0aedb885-2947-484f-81f8-6a8a8c90f7aa"

# Service Principal Object ID holen
SP_OBJECT_ID=$(az ad sp show --id "$APP_ID" --query id -o tsv)

# Reader auf Subscription-Scope (nur zum "Subscription sehen")
az role assignment create \
  --assignee-object-id "$SP_OBJECT_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "Reader" \
  --scope "/subscriptions/$SUBSCRIPTION_ID"
