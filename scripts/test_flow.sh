#!/usr/bin/env bash
set -euo pipefail

: "${PROJECT_ID:?Set PROJECT_ID}"
REGION="${REGION:-asia-northeast3}"
SERVICE_NAME="${SERVICE_NAME:-infra-manager-colab-adapter}"
REQUEST_FILE="${REQUEST_FILE:-../examples/task-request.json}"

if [[ ! -f "${REQUEST_FILE}" ]]; then
  echo "Request file not found: ${REQUEST_FILE}" >&2
  exit 1
fi

SERVICE_URL="${SERVICE_URL:-$(gcloud run services describe "${SERVICE_NAME}" \
  --project="${PROJECT_ID}" \
  --region="${REGION}" \
  --format='value(status.url)')}"

if [[ -z "${SERVICE_URL}" ]]; then
  echo "Unable to resolve Cloud Run service URL" >&2
  exit 1
fi

AUTH_HEADER=()
if [[ "${UNAUTHENTICATED:-false}" != "true" ]]; then
  TOKEN="$(gcloud auth print-identity-token --audiences="${SERVICE_URL}")"
  AUTH_HEADER=(-H "Authorization: Bearer ${TOKEN}")
fi

echo "== Health =="
curl -fsS "${AUTH_HEADER[@]}" "${SERVICE_URL}/health" | jq .

echo
echo "== Preview =="
curl -fsS "${AUTH_HEADER[@]}" \
  -H 'Content-Type: application/json' \
  -X POST "${SERVICE_URL}/preview" \
  --data-binary "@${REQUEST_FILE}" | jq .

echo
echo "== Deploy =="
RESPONSE="$(curl -fsS "${AUTH_HEADER[@]}" \
  -H 'Content-Type: application/json' \
  -X POST "${SERVICE_URL}/deploy" \
  --data-binary "@${REQUEST_FILE}")"
echo "${RESPONSE}" | jq .

OPERATION="$(echo "${RESPONSE}" | jq -r '.operation // empty')"
if [[ -z "${OPERATION}" ]]; then
  echo "No operation returned. Check the response above."
  exit 0
fi

echo
echo "== Operation status =="
for i in {1..60}; do
  STATUS="$(curl -fsS "${AUTH_HEADER[@]}" \
    --get "${SERVICE_URL}/status" \
    --data-urlencode "operation=${OPERATION}")"
  echo "${STATUS}" | jq .

  DONE="$(echo "${STATUS}" | jq -r '.done // false')"
  if [[ "${DONE}" == "true" ]]; then
    break
  fi
  sleep 10
done
