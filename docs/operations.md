# Colab Enterprise Deployment / Verification Runbook

## 0. 변수

```bash
export PROJECT_ID=dev-com-334508
export TARGET_PROJECT_ID=dev-com-334508
export COLAB_PROJECT_ID=dev-com-334508
export NETWORK_PROJECT_ID=dev-com-334508
export REGION=asia-northeast3
export NETWORK_NAME=managed02-dev-vpc
export SUBNETWORK_NAME=managed02-dev-subnet
```

운영에서 Shared VPC를 쓰면 `NETWORK_PROJECT_ID`는 host project로 지정한다.

## 1. API 확인

```bash
gcloud services list --enabled \
  --project="${COLAB_PROJECT_ID}" \
  --filter='name:(aiplatform.googleapis.com OR dataform.googleapis.com OR compute.googleapis.com)'
```

Foundation Infrastructure Manager deployment가 API를 활성화하지만 최초 bootstrap을 수행하기 위해 `config.googleapis.com`, Cloud Run/Cloud Build/Artifact Registry 관련 API는 기존 플랫폼 bootstrap에서 먼저 활성화되어 있어야 한다.

## 2. Bootstrap

관리자 권한으로 1회 실행한다.

```bash
cd infra-manager/terraform/bootstrap
terraform init
terraform plan  -var="project_id=${PROJECT_ID}"
terraform apply -var="project_id=${PROJECT_ID}"
```

생성 계정:

```text
infra-manager-exec@PROJECT_ID.iam.gserviceaccount.com
infra-adapter@PROJECT_ID.iam.gserviceaccount.com
```

PoC bootstrap은 broad role을 사용한다. 운영 전에는 custom role로 축소한다.

## 3. Cross-project data project 권한

`TARGET_PROJECT_ID != PROJECT_ID`이면 Infrastructure Manager 실행 SA가 target data project에서 BigQuery/GCS/Service Account/IAM을 생성할 권한이 추가로 필요하다.

예시(PoC):

```bash
IM_EXEC_SA="infra-manager-exec@${PROJECT_ID}.iam.gserviceaccount.com"

for ROLE in \
  roles/bigquery.admin \
  roles/storage.admin \
  roles/iam.serviceAccountAdmin \
  roles/resourcemanager.projectIamAdmin
do
  gcloud projects add-iam-policy-binding "${TARGET_PROJECT_ID}" \
    --member="serviceAccount:${IM_EXEC_SA}" \
    --role="${ROLE}"
done
```

운영에서는 위 broad role 대신 생성 대상 resource/permission만 포함하는 custom role을 사용한다.

## 4. Shared VPC 권한

Colab service project와 VPC host project가 다르면 project number를 확인한다.

```bash
COLAB_PROJECT_NUMBER="$(gcloud projects describe "${COLAB_PROJECT_ID}" \
  --format='value(projectNumber)')"
```

Agent Platform service agent에 host project/subnet Network User를 부여한다.

```bash
gcloud projects add-iam-policy-binding "${NETWORK_PROJECT_ID}" \
  --member="serviceAccount:service-${COLAB_PROJECT_NUMBER}@gcp-sa-aiplatform.iam.gserviceaccount.com" \
  --role="roles/compute.networkUser"
```

Notebook Execution/Schedule 기능도 사용할 경우 Colab service agent에도 부여한다.

```bash
gcloud projects add-iam-policy-binding "${NETWORK_PROJECT_ID}" \
  --member="serviceAccount:service-${COLAB_PROJECT_NUMBER}@gcp-sa-vertex-nb.iam.gserviceaccount.com" \
  --role="roles/compute.networkUser"
```

가능하면 host project 전체가 아니라 사용 subnet에 IAM을 부여한다.

## 5. Private Google Access 확인

`enableInternetAccess=false`를 사용할 경우 subnet 설정을 확인한다.

```bash
gcloud compute networks subnets describe "${SUBNETWORK_NAME}" \
  --project="${NETWORK_PROJECT_ID}" \
  --region="${REGION}" \
  --format='yaml(name,region,network,privateIpGoogleAccess,ipCidrRange)'
```

필요한 경우 플랫폼/네트워크 관리자 승인 후:

```bash
gcloud compute networks subnets update "${SUBNETWORK_NAME}" \
  --project="${NETWORK_PROJECT_ID}" \
  --region="${REGION}" \
  --enable-private-ip-google-access
```

기존 운영 subnet을 공유한다면 Terraform foundation이 이 값을 강제로 변경하지 않는다.

## 6. Cloud Run Adapter 배포

```bash
cd cloud-run-adapter

export PROJECT_ID
export TARGET_PROJECT_ID
export COLAB_PROJECT_ID
export NETWORK_PROJECT_ID
export REGION
export NETWORK_NAME
export SUBNETWORK_NAME

./deploy.sh
```

기본은 authenticated Cloud Run이다. 단순 PoC에서만 다음을 사용할 수 있다.

```bash
export ALLOW_UNAUTHENTICATED=true
./deploy.sh
```

## 7. Portal JSON 사전 검증

```bash
SERVICE_URL="$(gcloud run services describe infra-manager-colab-adapter \
  --project="${PROJECT_ID}" \
  --region="${REGION}" \
  --format='value(status.url)')"

TOKEN="$(gcloud auth print-identity-token --audiences="${SERVICE_URL}")"

curl -sS \
  -H "Authorization: Bearer ${TOKEN}" \
  -H 'Content-Type: application/json' \
  -X POST "${SERVICE_URL}/preview" \
  --data-binary @examples/task-request.json | jq .
```

확인 항목:

- `colab_project_id`
- `target_project_id`
- `network_project_id`
- `request_user`, `team_users_csv`
- `machine_type`
- `disk_size_gb`
- `enable_internet_access=false`
- `enable_end_user_credentials=true`
- `runtime_desired_state=STOPPED`

## 8. End-to-end 배포

repo root 기준:

```bash
cd scripts
export PROJECT_ID
./test_flow.sh
```

이 스크립트는 다음 순서로 확인한다.

```text
/health
  -> /preview
  -> /deploy
  -> Infrastructure Manager operation polling
```

## 9. Infrastructure Manager 확인

```bash
gcloud infra-manager deployments list \
  --project="${PROJECT_ID}" \
  --location="${REGION}"
```

예상:

```text
foundation-colab-analysis   ACTIVE
model-001                   ACTIVE
```

상세:

```bash
gcloud infra-manager deployments describe model-001 \
  --project="${PROJECT_ID}" \
  --location="${REGION}"
```

## 10. Colab Runtime Template 확인

```bash
gcloud colab runtime-templates list \
  --project="${COLAB_PROJECT_ID}" \
  --region="${REGION}"
```

과제 `model-001`이면 `rtpl-model-001` 형태의 template을 확인한다.

IAM:

```bash
gcloud colab runtime-templates get-iam-policy rtpl-model-001 \
  --project="${COLAB_PROJECT_ID}" \
  --region="${REGION}"
```

승인 사용자에게 `roles/aiplatform.notebookRuntimeUser`가 보여야 한다.

## 11. 사용자 Runtime 확인

```bash
gcloud colab runtimes list \
  --project="${COLAB_PROJECT_ID}" \
  --region="${REGION}"
```

5명 요청이면 사용자별 runtime 5개를 기대한다. 기본 `runtimeDesiredState=STOPPED`이므로 승인 직후 항상 실행 중인 VM을 만들지 않는 것이 목표다.

## 12. BigQuery / GCS 확인

```bash
bq --project_id="${TARGET_PROJECT_ID}" ls

gcloud storage buckets list \
  --project="${TARGET_PROJECT_ID}" \
  --filter="name:model-001-colab"
```

Dataset:

```text
ds_model_001
```

Bucket:

```text
gs://TARGET_PROJECT_ID-model-001-colab
```

## 13. 사용자 데이터 접근 확인

Notebook에서:

```python
from google.cloud import bigquery, storage
import os

print(os.environ.get("DATA_MODEL_DATASET"))
print(os.environ.get("DATA_MODEL_WORKSPACE_BUCKET"))

bq = bigquery.Client()
print(list(bq.list_datasets()))

storage_client = storage.Client()
print([b.name for b in storage_client.list_buckets()])
```

`enableEndUserCredentials=true`에서는 사용자 IAM이 적용되므로 권한이 없는 다른 과제 Dataset/GCS에는 접근할 수 없어야 한다.

## 14. GPU 과제

승인 JSON 예:

```json
{
  "machineType": "n1-standard-8",
  "acceleratorType": "NVIDIA_TESLA_T4",
  "acceleratorCount": 1
}
```

GPU quota 및 해당 리전 accelerator availability를 별도로 확인한다.

## 15. 과제 종료

Infrastructure Manager deployment 삭제 전에 확인:

1. Notebook/code asset 보존
2. GCS workspace 백업
3. BigQuery dataset 보존/이관
4. Runtime disk 삭제 여부
5. `allowDestroyData=false` 유지 여부

데이터 보존이 필요한 운영환경에서는 `allowDestroyData=false`를 유지하고 데이터 자원의 lifecycle/state 분리를 검토한다.

## 16. 공통 Colab project에서의 IAM 주의

`roles/aiplatform.colabEnterpriseUser`는 Notebook/Dataform 관련 project-level 권한을 포함한다. 다수 과제를 하나의 Colab project에 넣는 경우 Notebook 코드 자산 가시성 요구사항을 별도로 검토한다.

권장 운영:

- 3~5개 분석 Group별 Colab project
- 과제별 Runtime Template IAM
- 과제별 BigQuery/GCS IAM
- 강한 코드 격리가 필요하면 custom role + notebook resource IAM
- 사용자 project-level 공통 역할은 중앙 Google Group으로 관리하여 과제 Terraform state 간 IAM 충돌을 피한다.
