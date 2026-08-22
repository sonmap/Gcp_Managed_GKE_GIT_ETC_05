# Colab Enterprise Target Architecture

## 1. ETC_04 -> ETC_05 변환 원칙

ETC_04의 핵심은 포털 승인 흐름과 Infrastructure Manager 자동화이므로 이 부분은 유지한다.
Kubernetes 실행 계층만 Colab Enterprise 관리형 Runtime 계층으로 바꾼다.

```text
[ETC_04]
Portal
  -> Cloud Run Adapter
  -> Infrastructure Manager
  -> GKE Autopilot
      -> Namespace
      -> ResourceQuota
      -> KSA/GSA Workload Identity
      -> PVC
      -> Jupyter Pod
      -> Service

[ETC_05]
Portal
  -> Cloud Run Adapter
  -> Infrastructure Manager
  -> Colab Enterprise
      -> Runtime Template / task
      -> Runtime / user
      -> Persistent data disk / runtime
      -> End-User Credentials
      -> Existing private VPC/Subnet
  -> BigQuery Dataset / task
  -> GCS workspace bucket / task
  -> IAM / task + user
```

## 2. Foundation과 Task 분리

### Foundation deployment

`foundation-colab-analysis`

- Colab/Agent Platform API 활성화
- Dataform, Compute, BigQuery, Storage API 활성화
- 기존 사내 VPC/Subnet 존재 여부 확인
- GKE Cluster는 생성하지 않음

### Task deployment

예: `model-001`

- BigQuery Dataset 1개
- GCS workspace bucket 1개
- Runtime Template 1개
- 승인 사용자 수만큼 Runtime 생성
- Runtime 기본 상태 STOPPED
- Runtime persistent disk 사용자별 생성
- Dataset/GCS 사용자 IAM
- Colab Runtime Template IAM
- 비대화형 실행용 task Service Account 생성

## 3. 5명 과제 예시

```text
Task model-001
  |
  +-- Runtime Template: rtpl-model-001
  |
  +-- Runtime: user01  (STOPPED)
  +-- Runtime: user02  (STOPPED)
  +-- Runtime: user03  (STOPPED)
  +-- Runtime: user04  (STOPPED)
  +-- Runtime: user05  (STOPPED)
  |
  +-- BigQuery: ds_model_001
  +-- GCS: <project>-model-001-colab
  +-- task SA: colab-model-001@...
```

사용자가 실제 작업을 시작할 때만 Runtime compute가 실행되고 idle timeout 이후 자동 종료하는 운영을 기본으로 한다.

## 4. Identity

### Interactive Notebook

기본값: `enableEndUserCredentials=true`

```text
Corporate User
  -> Google Identity / SSO
  -> Colab Notebook
  -> End-User Credentials
  -> BigQuery/GCS IAM
```

따라서 GKE의 KSA -> GSA Workload Identity와 달리, 대화형 Notebook에서 서비스 계정 JSON key를 배포하지 않는다.

### Scheduled / non-interactive

Task마다 별도 Service Account를 만든다.
이 SA는 BigQuery Job User + 해당 Dataset + 해당 GCS workspace만 접근하도록 구성한다.
Notebook Execution/Scheduler 적용 시 이 SA를 실행 identity로 사용한다.

## 5. Notebook 격리 주의

Colab Enterprise Notebook은 Dataform 기반 코드 자산이다.
표준 Colab Enterprise User 역할에는 project-level Dataform 조회 권한이 포함될 수 있으므로, 하나의 공통 Colab project에서 모든 과제를 운영할 경우 Notebook 목록 가시성이 과제 경계를 넘을 수 있다.

운영 선택지는 다음과 같다.

1. PoC/저위험: 공통 Colab project + 표준 Colab role
2. 권장: 3~5개 분석 Group별 Colab project + 과제별 BigQuery/GCS IAM
3. 강한 격리: Custom Role에서 `dataform.repositories.list` 제외 + Notebook resource IAM
4. 최고 격리: 과제별 project 유지

데이터 접근 자체는 Dataset/GCS IAM으로 과제별 분리된다. Notebook 코드 자산의 가시성과 데이터 권한은 별개로 설계해야 한다.

## 6. Network

기본값은 public internet OFF이다.

```text
Colab Runtime
   |
   +-- existing VPC/Subnet
   |
   +-- Internal Data Lake / Redis / Cloud SQL / NAS endpoint
   |
   +-- Private Google Access / PSC -> Google APIs
```

확인 항목:

- subnet Private Google Access
- 사내 DNS
- route
- egress firewall
- 내부 데이터레이크 목적지 firewall
- 필요 시 Cloud NAT/proxy
- VPC Service Controls perimeter

### Shared VPC

Colab project가 service project이고 VPC가 host project에 있으면 Agent Platform/Colab service agent에 host project의 `roles/compute.networkUser`가 필요할 수 있다.

특히 scheduled notebook execution을 사용할 경우 Colab service agent(`service-<PROJECT_NUMBER>@gcp-sa-vertex-nb.iam.gserviceaccount.com`)에 Shared VPC subnet 사용 권한을 확인한다.

## 7. Storage

### Runtime persistent disk

사용자 개인 Runtime 작업 파일/패키지 캐시용이다.
Runtime을 STOPPED해도 persistent disk 비용은 남는다.

### GCS workspace

팀 공유 데이터/산출물용이다.
기존 GKE PVC 하나를 5명이 공유하던 방식보다 권한/수명주기를 명확히 관리할 수 있다.

Notebook 자체는 Colab Enterprise/Dataform code asset으로 관리한다.

## 8. 비용 제어

- Runtime 생성 기본 `STOPPED`
- Idle shutdown 기본 60분
- Machine type은 과제 승인값으로 지정
- GPU는 acceleratorType/acceleratorCount 승인 시에만 생성
- GCS와 persistent disk는 compute 종료 후에도 저장 비용 발생
- 과제 종료 시 Terraform destroy 전에 데이터 보존/백업 정책 확인

## 9. Git / Secure Source Manager

Colab Runtime은 기존 private VPC를 사용하므로 내부 Git/Secure Source Manager endpoint가 해당 VPC에서 접근 가능하면 Notebook shell 또는 startup script에서 clone/pull이 가능하다.

인증 정보는 이미지/스크립트에 하드코딩하지 않는다.
권장 방식:

- 사용자 SSO/credential helper
- Workload/identity federation 또는 단기 토큰
- Secret Manager + 최소권한
- 사내 proxy/Private DNS

## 10. 권장 운영 단위

기존 과제 200개를 그대로 200개 Colab project로 옮기기보다 다음 구조를 권장한다.

```text
Group-A Colab Project
  - task-001 template/runtimes
  - task-002 template/runtimes
  - ...

Group-B Colab Project
  - task-101 template/runtimes
  - ...
```

BigQuery Dataset과 GCS IAM은 과제별로 유지하고, Runtime quota/GPU quota는 Group project 단위로 관리한다.
