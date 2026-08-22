# GCP Managed Data Model Workspace - Colab Enterprise

`Gcp_Managed_GKE_GIT_ETC_04`의 포털 승인 -> Cloud Run Adapter -> Infrastructure Manager -> Terraform 흐름은 유지하면서, 과제 실행 영역을 **GKE Autopilot + Jupyter Pod**에서 **Colab Enterprise Runtime**으로 전환한 PoC/Reference 구현입니다.

## 핵심 전환

```text
AS-IS (ETC_04)
Portal -> Cloud Run Adapter -> Infrastructure Manager
       -> GKE Autopilot
          -> Namespace / Quota / KSA-GSA / PVC / Jupyter Pod / Service

TO-BE (ETC_05)
Portal -> Cloud Run Adapter -> Infrastructure Manager
       -> Colab Enterprise
          -> Runtime Template (과제별)
          -> Runtime (사용자별, 기본 STOPPED)
          -> Persistent Disk
          -> End-User Credentials
          -> Private VPC/Subnet
       -> BigQuery Dataset (과제별)
       -> GCS Workspace Bucket (과제별 공유 데이터)
       -> IAM (사용자/과제별 최소권한)
```

## GKE -> Colab 매핑

| ETC_04 GKE 구성 | ETC_05 Colab Enterprise 구성 |
|---|---|
| GKE Autopilot Cluster | Google-managed Colab Enterprise runtime infrastructure |
| Namespace | 과제별 Runtime Template + labels |
| ResourceQuota | Machine type / accelerator / disk / idle shutdown / 조직 quota |
| Jupyter Deployment/Pod | 사용자별 Colab Runtime |
| PVC | Runtime persistent data disk + 과제별 GCS bucket |
| KSA -> GSA Workload Identity | Interactive: End-User Credentials, Batch/Schedule: task Service Account |
| ClusterIP / Ingress | Google Cloud Console / Colab Enterprise UI |
| Pod/Node firewall | Runtime Template VPC/Subnet + VPC firewall/VPC-SC |

## 목표 구조

```text
사내 사용자 / Cloud PC
       |
       | SSO / Google identity
       v
업무 포털(Java Web)
       |
       | 승인 JSON
       v
Cloud Run Adapter
       |
       | Infrastructure Manager REST API
       v
Infrastructure Manager
       |
       | GitHub Terraform Blueprint
       +------------------------------+
       |                              |
       v                              v
Foundation Deployment            Task Deployment (과제마다)
- APIs                           - BigQuery Dataset
- Colab project                 - GCS Workspace Bucket
- Existing VPC/Subnet 확인       - Runtime Template
                                 - Runtime / user
                                 - Colab IAM
                                 - BigQuery/GCS IAM
                                 - task Service Account(optional batch)
```

## 프로젝트 모델

- `COLAB_PROJECT_ID`: 공통 Colab Enterprise 실행 프로젝트. 기존 GKE 공유 Cluster 프로젝트에 대응합니다.
- `targetProjectId`: 과제 데이터가 위치하는 프로젝트. BigQuery Dataset/GCS workspace를 생성합니다.
- `NETWORK_PROJECT_ID`: Shared VPC host project 또는 Colab project.

작은 PoC에서는 세 값을 동일 프로젝트로 사용해도 됩니다. 운영에서는 Colab 실행 프로젝트와 데이터 프로젝트를 분리할 수 있습니다.

## 디렉터리

```text
infra-manager/terraform/bootstrap/       최초 1회 IAM/SA 준비
infra-manager/terraform/foundation/      Colab 공통 API/VPC foundation
infra-manager/terraform/task-blueprint/  과제별 Colab/BigQuery/GCS/IAM
cloud-run-adapter/                       포털 JSON -> IM 입력값 변환
portal-integration/                      Java 호출 예제
docs/                                    설계/운영/테스트 문서
examples/                                승인 요청 JSON 예제
scripts/                                 검증용 gcloud/curl 스크립트
```

## 사용자 모델

`requestUser` 1명뿐 아니라 `teamUsers` 배열을 받을 수 있습니다. 최종 사용자 목록은 `requestUser + teamUsers` 중복 제거 결과입니다.

각 사용자마다 Colab Runtime을 하나 생성하며 기본 상태는 `STOPPED`입니다. 따라서 과제 승인 직후 VM compute 비용을 계속 발생시키지 않고, 사용 시점에 Runtime을 시작하는 운영을 기본으로 합니다.

대화형 Notebook은 End-User Credentials(EUC)를 기본 활성화하여 사용자의 Google Cloud IAM으로 BigQuery/GCS에 접근합니다. 서비스 계정 JSON key를 Runtime에 배포하지 않습니다.

## 요청 예시

```json
{
  "taskId": "model-001",
  "taskName": "fraud-detection-model",
  "requestUser": "user01@example.com",
  "teamUsers": [
    "user02@example.com",
    "user03@example.com",
    "user04@example.com",
    "user05@example.com"
  ],
  "group": "fraud",
  "targetProjectId": "dev-com-334508",
  "location": "asia-northeast3",
  "machineType": "e2-standard-4",
  "diskSizeGb": 100,
  "idleShutdownMinutes": 60,
  "enableInternetAccess": false,
  "enableEndUserCredentials": true,
  "runtimeDesiredState": "STOPPED",
  "bigqueryRole": "editor",
  "expireDate": "2026-12-31"
}
```

## 적용 순서

```bash
# 1. 최초 bootstrap (관리자)
cd infra-manager/terraform/bootstrap
terraform init
terraform apply -var="project_id=dev-com-334508"

# 2. Cloud Run Adapter 배포
cd ../../../cloud-run-adapter
export IM_PROJECT_ID=dev-com-334508
export COLAB_PROJECT_ID=dev-com-334508
export NETWORK_PROJECT_ID=dev-com-334508
./deploy.sh

# 3. 승인 JSON 테스트
cd ../scripts
./test_flow.sh
```

## 네트워크 기본값

운영 기본은 `enableInternetAccess=false`입니다. 이 경우 Runtime이 Google APIs/내부 데이터레이크에 접근하려면 사용하는 subnet의 **Private Google Access**, DNS, route, 방화벽, 필요 시 Cloud NAT 또는 Private Service Connect 구성을 별도로 확인해야 합니다.

Shared VPC 환경에서는 `NETWORK_PROJECT_ID`를 host project로 지정합니다.

## 비용 제어

- Runtime 기본 `STOPPED`
- `idleShutdownMinutes` 기본 60분
- 사용자별 runtime이므로 동시 사용자만 compute 사용
- Runtime persistent disk는 Runtime 중지 중에도 disk 비용 발생
- 과제 공유 파일은 GCS bucket 사용
- GPU는 승인 JSON의 accelerator 설정으로 과제별 선택 가능

## 보안 원칙

- 사용자 계정은 Cloud Identity/Workspace/사내 IdP에서 관리
- SA JSON key 미사용
- Runtime public internet 기본 차단
- BigQuery Dataset과 GCS bucket은 과제별 IAM
- 필요 시 VPC Service Controls + CMEK 추가
- Infrastructure Manager 실행 SA는 bootstrap에서만 권한 부여

## ETC_04와의 중요한 차이

Colab Enterprise는 Kubernetes가 아니므로 Namespace/KSA/PVC/Service를 그대로 옮기는 방식이 아닙니다. **Runtime Template이 과제의 실행 정책**, **Runtime이 사용자 작업 세션**, **persistent disk와 GCS가 작업 데이터 저장 계층**, **IAM/EUC가 Pod Workload Identity의 역할**을 담당합니다.
