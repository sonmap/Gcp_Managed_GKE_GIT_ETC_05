#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

echo "[1/4] Python syntax"
python3 -m py_compile cloud-run-adapter/app.py

echo "[2/4] Bash syntax"
bash -n cloud-run-adapter/deploy.sh
bash -n scripts/test_flow.sh
bash -n scripts/validate.sh

echo "[3/4] JSON syntax"
python3 -m json.tool examples/task-request.json >/dev/null

echo "[4/4] Terraform format / validate"
if ! command -v terraform >/dev/null 2>&1; then
  echo "terraform is not installed; skipping Terraform fmt/validate" >&2
  exit 0
fi

terraform fmt -check -recursive infra-manager/terraform

for DIR in \
  infra-manager/terraform/bootstrap \
  infra-manager/terraform/foundation \
  infra-manager/terraform/task-blueprint
do
  echo "-- ${DIR}"
  terraform -chdir="${DIR}" init -backend=false -input=false >/dev/null
  terraform -chdir="${DIR}" validate
 done

echo "Validation complete."
