#!/usr/bin/env bash
# Desplega OpenProject a Azure Container Apps en 4 passos:
#   1. Crea el resource group i la infraestructura base (azure/infra.bicep)
#   2. Construeix la imatge (amb el patch ACS) al núvol via az acr build
#   3. Desplega els Container Apps + Job (azure/apps.bicep)
#   4. Executa el job de migració/seed un cop
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

RESOURCE_GROUP="${RESOURCE_GROUP:-rg_openproject}"
LOCATION="${LOCATION:-westeurope}"
APP_NAME="${APP_NAME:-openproject}"
IMAGE_TAG="${IMAGE_TAG:-1.0}"
SECRETS_FILE="$SCRIPT_DIR/.deploy-secrets.env"

log() { echo -e "\n==> $*"; }

log "Comprovant sessió d'Azure CLI..."
az account show >/dev/null

log "Generant/reutilitzant secrets locals (${SECRETS_FILE})..."
if [ -f "$SECRETS_FILE" ]; then
  # shellcheck disable=SC1090
  source "$SECRETS_FILE"
else
  POSTGRES_ADMIN_PASSWORD="$(openssl rand -base64 24)"
  SECRET_KEY_BASE="$(head -c 48 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 32)"
  {
    echo "POSTGRES_ADMIN_PASSWORD='${POSTGRES_ADMIN_PASSWORD}'"
    echo "SECRET_KEY_BASE='${SECRET_KEY_BASE}'"
  } > "$SECRETS_FILE"
  chmod 600 "$SECRETS_FILE"
fi

log "Creant resource group ${RESOURCE_GROUP} a ${LOCATION}..."
az group create --name "$RESOURCE_GROUP" --location "$LOCATION" >/dev/null

log "Desplegant infraestructura base (infra.bicep)..."
INFRA_OUT="$SCRIPT_DIR/infra.outputs.json"
az deployment group create \
  --resource-group "$RESOURCE_GROUP" \
  --template-file "$SCRIPT_DIR/infra.bicep" \
  --parameters appName="$APP_NAME" \
               location="$LOCATION" \
               postgresAdminPassword="$POSTGRES_ADMIN_PASSWORD" \
  --query properties.outputs -o json > "$INFRA_OUT"

jq_out() { jq -r ".${1}.value" "$INFRA_OUT"; }

ACR_NAME="$(jq_out acrName)"
ACR_LOGIN_SERVER="$(jq_out acrLoginServer)"
ACR_ADMIN_USERNAME="$(jq_out acrAdminUsername)"
ACR_ADMIN_PASSWORD="$(jq_out acrAdminPassword)"
DATABASE_URL="$(jq_out databaseUrl)"
CAE_ID="$(jq_out containerAppsEnvironmentId)"
CAE_DEFAULT_DOMAIN="$(jq_out containerAppsEnvironmentDefaultDomain)"
ENV_STORAGE_NAME="$(jq_out envStorageName)"
ACS_ENDPOINT="$(jq_out communicationServiceEndpoint)"
ACS_KEY="$(jq_out communicationServiceKey)"
ACS_SENDER="$(jq_out emailSenderAddress)"

log "Construint la imatge amb el patch ACS via az acr build (pot trigar uns minuts)..."
az acr build \
  --registry "$ACR_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --image "openproject:${IMAGE_TAG}" \
  --file "$REPO_ROOT/docker/prod/Dockerfile" \
  --target slim \
  --timeout 3600 \
  "$REPO_ROOT"

log "Desplegant Container Apps (web, worker) i el Job de seed (apps.bicep)..."
APPS_OUT="$SCRIPT_DIR/apps.outputs.json"
az deployment group create \
  --resource-group "$RESOURCE_GROUP" \
  --template-file "$SCRIPT_DIR/apps.bicep" \
  --parameters appName="$APP_NAME" \
               location="$LOCATION" \
               containerAppsEnvironmentId="$CAE_ID" \
               containerAppsEnvironmentDefaultDomain="$CAE_DEFAULT_DOMAIN" \
               envStorageName="$ENV_STORAGE_NAME" \
               acrLoginServer="$ACR_LOGIN_SERVER" \
               acrAdminUsername="$ACR_ADMIN_USERNAME" \
               acrAdminPassword="$ACR_ADMIN_PASSWORD" \
               databaseUrl="$DATABASE_URL" \
               secretKeyBase="$SECRET_KEY_BASE" \
               communicationServiceEndpoint="$ACS_ENDPOINT" \
               communicationServiceKey="$ACS_KEY" \
               emailSenderAddress="$ACS_SENDER" \
               image="${ACR_LOGIN_SERVER}/openproject:${IMAGE_TAG}" \
  --query properties.outputs -o json > "$APPS_OUT"

WEB_URL="$(jq -r '.webUrl.value' "$APPS_OUT")"
SEEDER_JOB_NAME="$(jq -r '.seederJobName.value' "$APPS_OUT")"

log "Executant el job de migració/seed (${SEEDER_JOB_NAME})..."
az containerapp job start --name "$SEEDER_JOB_NAME" --resource-group "$RESOURCE_GROUP" >/dev/null

log "Fet. OpenProject hauria d'estar accessible a: ${WEB_URL}"
echo "(La primera càrrega pot trigar mentre acaba el job de seed; comprova l'estat amb:"
echo " az containerapp job execution list -n ${SEEDER_JOB_NAME} -g ${RESOURCE_GROUP} -o table)"
