#!/usr/bin/env bash
set -euo pipefail

: "${PROJECT_ID:?Set PROJECT_ID (Infrastructure Manager / Cloud Run project)}"
: "${TARGET_PROJECT_ID:?Set TARGET_PROJECT_ID (default BigQuery/GCS data project)}"

REGION="${REGION:-asia-northeast3}"
COLAB_PROJECT_ID="${COLAB_PROJECT_ID:-${PROJECT_ID}}"
NETWORK_PROJECT_ID="${NETWORK_PROJECT_ID:-${COLAB_PROJECT_ID}}"
NETWORK_NAME="${NETWORK_NAME:-managed02-dev-vpc}"
SUBNETWORK_NAME="${SUBNETWORK_NAME:-managed02-dev-subnet}"
REPO_NAME="${REPO_NAME:-infra-poc}"
SERVICE_NAME="${SERVICE_NAME:-infra-manager-colab-adapter}"
ADAPTER_SA="${ADAPTER_SA:-infra-adapter@${PROJECT_ID}.iam.gserviceaccount.com}"
IM_EXEC_SA="${IM_EXEC_SA:-infra-manager-exec@${PROJECT_ID}.iam.gserviceaccount.com}"
IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO_NAME}/cloud-run-colab-adapter:latest"
ALLOW_UNAUTHENTICATED="${ALLOW_UNAUTHENTICATED:-false}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "[1/3] Build adapter container"
gcloud builds submit "${SCRIPT_DIR}" \
  --project="${PROJECT_ID}" \
  --region="${REGION}" \
  --tag="${IMAGE}"

echo "[2/3] Deploy Cloud Run adapter"
AUTH_FLAG="--no-allow-unauthenticated"
if [[ "${ALLOW_UNAUTHENTICATED}" == "true" ]]; then
  AUTH_FLAG="--allow-unauthenticated"
fi

gcloud run deploy "${SERVICE_NAME}" \
  --project="${PROJECT_ID}" \
  --region="${REGION}" \
  --image="${IMAGE}" \
  --service-account="${ADAPTER_SA}" \
  --timeout=900 \
  "${AUTH_FLAG}" \
  --set-env-vars="IM_PROJECT_ID=${PROJECT_ID},IM_LOCATION=${REGION},IM_SERVICE_ACCOUNT=projects/${PROJECT_ID}/serviceAccounts/${IM_EXEC_SA},DEFAULT_TARGET_PROJECT_ID=${TARGET_PROJECT_ID},COLAB_PROJECT_ID=${COLAB_PROJECT_ID},COLAB_LOCATION=${REGION},NETWORK_PROJECT_ID=${NETWORK_PROJECT_ID},NETWORK_NAME=${NETWORK_NAME},SUBNETWORK_NAME=${SUBNETWORK_NAME},TF_REPO_URL=https://github.com/sonmap/Gcp_Managed_GKE_GIT_ETC_05.git,TF_REPO_REF=main,TF_DIRECTORY=infra-manager/terraform/task-blueprint,FOUNDATION_TF_DIRECTORY=infra-manager/terraform/foundation,FOUNDATION_DEPLOYMENT_ID=foundation-colab-analysis,AUTO_CREATE_FOUNDATION=true"

echo "[3/3] Service URL"
gcloud run services describe "${SERVICE_NAME}" \
  --project="${PROJECT_ID}" \
  --region="${REGION}" \
  --format='value(status.url)'

echo
if [[ "${ALLOW_UNAUTHENTICATED}" == "true" ]]; then
  echo "WARNING: unauthenticated access is enabled for PoC testing."
else
  echo "Cloud Run requires authenticated invocation (recommended)."
fi
