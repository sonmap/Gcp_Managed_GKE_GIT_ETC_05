import os
import re
import time
import uuid
from typing import Any, Dict, List

from flask import Flask, jsonify, request
import google.auth
from google.auth.transport.requests import AuthorizedSession

app = Flask(__name__)

API_ROOT = "https://config.googleapis.com/v1"
IM_PROJECT_ID = os.environ["IM_PROJECT_ID"]
IM_LOCATION = os.getenv("IM_LOCATION", "asia-northeast3")
IM_SERVICE_ACCOUNT = os.environ["IM_SERVICE_ACCOUNT"]

TF_REPO_URL = os.getenv(
    "TF_REPO_URL",
    "https://github.com/sonmap/Gcp_Managed_GKE_GIT_ETC_05.git",
)
TF_REPO_REF = os.getenv("TF_REPO_REF", "main")
TASK_TF_DIRECTORY = os.getenv("TF_DIRECTORY", "infra-manager/terraform/task-blueprint")
FOUNDATION_TF_DIRECTORY = os.getenv(
    "FOUNDATION_TF_DIRECTORY", "infra-manager/terraform/foundation"
)
FOUNDATION_DEPLOYMENT_ID = os.getenv("FOUNDATION_DEPLOYMENT_ID", "foundation-colab-analysis")

DEFAULT_TARGET_PROJECT_ID = os.getenv("DEFAULT_TARGET_PROJECT_ID", "")
COLAB_PROJECT_ID = os.getenv("COLAB_PROJECT_ID", IM_PROJECT_ID)
COLAB_LOCATION = os.getenv("COLAB_LOCATION", IM_LOCATION)
NETWORK_PROJECT_ID = os.getenv("NETWORK_PROJECT_ID", COLAB_PROJECT_ID)
NETWORK_NAME = os.getenv("NETWORK_NAME", "managed02-dev-vpc")
SUBNETWORK_NAME = os.getenv("SUBNETWORK_NAME", "managed02-dev-subnet")

AUTO_CREATE_FOUNDATION = os.getenv("AUTO_CREATE_FOUNDATION", "true").lower() == "true"
FOUNDATION_WAIT_SECONDS = int(os.getenv("FOUNDATION_WAIT_SECONDS", "780"))
FOUNDATION_POLL_SECONDS = int(os.getenv("FOUNDATION_POLL_SECONDS", "10"))

credentials, _ = google.auth.default(scopes=["https://www.googleapis.com/auth/cloud-platform"])
authed = AuthorizedSession(credentials)


def _first(payload: Dict[str, Any], *names: str, default=None):
    for name in names:
        value = payload.get(name)
        if value is not None and str(value).strip() != "":
            return value
    return default


def _safe_id(value: str, prefix: str = "task") -> str:
    value = str(value).lower().strip()
    value = re.sub(r"[^a-z0-9-]", "-", value)
    value = re.sub(r"-+", "-", value).strip("-")
    if not value:
        value = f"{prefix}-{uuid.uuid4().hex[:8]}"
    if not value[0].isalpha():
        value = f"{prefix}-{value}"
    return value[:60].rstrip("-")


def _dataset_id(task_id: str) -> str:
    raw = re.sub(r"[^A-Za-z0-9_]", "_", task_id)
    raw = re.sub(r"_+", "_", raw).strip("_")
    if not raw:
        raw = uuid.uuid4().hex[:8]
    return f"ds_{raw}"[:1024]


def _bool_string(value: Any, default: bool) -> str:
    if value is None:
        return "true" if default else "false"
    if isinstance(value, bool):
        return "true" if value else "false"
    normalized = str(value).strip().lower()
    if normalized in {"true", "1", "yes", "y", "on"}:
        return "true"
    if normalized in {"false", "0", "no", "n", "off"}:
        return "false"
    raise ValueError(f"invalid boolean value: {value}")


def _team_users(payload: Dict[str, Any]) -> List[str]:
    raw = _first(payload, "teamUsers", "team_users", default=[])
    if isinstance(raw, list):
        values = raw
    elif isinstance(raw, str):
        values = raw.split(",")
    else:
        raise ValueError("teamUsers must be an array or comma-separated string")

    users = []
    for value in values:
        email = str(value).strip().lower()
        if email and email not in users:
            users.append(email)
    return users


def _parent() -> str:
    return f"projects/{IM_PROJECT_ID}/locations/{IM_LOCATION}"


def _deployment_name(deployment_id: str) -> str:
    return f"{_parent()}/deployments/{deployment_id}"


def _deployment_url(deployment_id: str) -> str:
    return f"{API_ROOT}/{_deployment_name(deployment_id)}"


def _json_or_text(response):
    try:
        return response.json()
    except Exception:
        return {"raw": response.text}


def _map_portal_json(payload: Dict[str, Any]) -> Dict[str, str]:
    task_id = str(
        _first(payload, "taskId", "task_id", "projectId", "project_id", "requestId")
        or ""
    ).strip()
    if not task_id:
        raise ValueError("taskId is required")

    target_project_id = str(
        _first(
            payload,
            "targetProjectId",
            "target_project_id",
            "gcpProjectId",
            "gcp_project_id",
            default=DEFAULT_TARGET_PROJECT_ID,
        )
        or ""
    ).strip()
    if not target_project_id:
        raise ValueError(
            "targetProjectId is required, or set DEFAULT_TARGET_PROJECT_ID on Cloud Run"
        )

    request_user = str(
        _first(payload, "requestUser", "request_user", "userEmail", "user_email", default="")
        or ""
    ).strip().lower()
    team_users = _team_users(payload)
    all_users = [u for u in [request_user] + team_users if u]
    if not all_users:
        raise ValueError("requestUser or teamUsers must contain at least one approved user")

    location = str(_first(payload, "location", "region", default=COLAB_LOCATION))
    bigquery_role = str(_first(payload, "bigqueryRole", "bigquery_role", default="editor")).lower()
    if bigquery_role not in {"viewer", "editor", "owner"}:
        raise ValueError("bigqueryRole must be viewer, editor, or owner")

    runtime_state = str(
        _first(payload, "runtimeDesiredState", "runtime_desired_state", default="STOPPED")
    ).upper()
    if runtime_state not in {"RUNNING", "STOPPED"}:
        raise ValueError("runtimeDesiredState must be RUNNING or STOPPED")

    accelerator_type = str(
        _first(payload, "acceleratorType", "accelerator_type", default="") or ""
    ).strip()
    accelerator_count = str(
        _first(
            payload,
            "acceleratorCount",
            "accelerator_count",
            default=1 if accelerator_type else 0,
        )
    )

    return {
        "task_id": task_id,
        "task_name": str(
            _first(payload, "taskName", "task_name", "projectName", default=task_id)
        ),
        "group": str(
            _first(payload, "group", "groupCode", "group_code", default="analysis")
        ).lower(),
        "request_user": request_user,
        "team_users_csv": ",".join(team_users),
        "colab_project_id": COLAB_PROJECT_ID,
        "target_project_id": target_project_id,
        "network_project_id": str(
            _first(payload, "networkProjectId", "network_project_id", default=NETWORK_PROJECT_ID)
        ),
        "network_name": str(_first(payload, "networkName", "network_name", default=NETWORK_NAME)),
        "subnetwork_name": str(
            _first(payload, "subnetworkName", "subnetwork_name", default=SUBNETWORK_NAME)
        ),
        "colab_location": location,
        "dataset_id": _dataset_id(task_id),
        "bq_location": str(_first(payload, "bqLocation", "bq_location", default=location)),
        "storage_location": str(
            _first(payload, "storageLocation", "storage_location", default=location)
        ),
        "bigquery_role": bigquery_role,
        "machine_type": str(
            _first(payload, "machineType", "machine_type", default="e2-standard-4")
        ),
        "accelerator_type": accelerator_type,
        "accelerator_count": accelerator_count,
        "disk_type": str(_first(payload, "diskType", "disk_type", default="pd-balanced")),
        "disk_size_gb": str(_first(payload, "diskSizeGb", "disk_size_gb", default=100)),
        "idle_shutdown_minutes": str(
            _first(payload, "idleShutdownMinutes", "idle_shutdown_minutes", default=60)
        ),
        "enable_internet_access": _bool_string(
            _first(payload, "enableInternetAccess", "enable_internet_access", default=None),
            False,
        ),
        "enable_end_user_credentials": _bool_string(
            _first(
                payload,
                "enableEndUserCredentials",
                "enable_end_user_credentials",
                default=None,
            ),
            True,
        ),
        "runtime_desired_state": runtime_state,
        "colab_release_name": str(
            _first(payload, "colabReleaseName", "colab_release_name", default="py312")
        ),
        "startup_script_url": str(
            _first(payload, "startupScriptUrl", "startup_script_url", default="") or ""
        ),
        "allow_destroy_data": _bool_string(
            _first(payload, "allowDestroyData", "allow_destroy_data", default=None),
            False,
        ),
        "kms_key_name": str(_first(payload, "kmsKeyName", "kms_key_name", default="") or ""),
        "expire_date": str(_first(payload, "expireDate", "expire_date", default="") or ""),
    }


def _foundation_inputs() -> Dict[str, str]:
    return {
        "project_id": COLAB_PROJECT_ID,
        "region": COLAB_LOCATION,
        "network_project_id": NETWORK_PROJECT_ID,
        "network_name": NETWORK_NAME,
        "subnetwork_name": SUBNETWORK_NAME,
    }


def _blueprint_body(
    directory: str,
    inputs: Dict[str, str],
    annotations: Dict[str, str],
    deployment_name: str | None = None,
):
    body = {
        "serviceAccount": IM_SERVICE_ACCOUNT,
        "terraformBlueprint": {
            "gitSource": {
                "repo": TF_REPO_URL,
                "directory": directory,
                "ref": TF_REPO_REF,
            },
            "inputValues": {
                key: {"inputValue": str(value)} for key, value in inputs.items()
            },
        },
        "annotations": annotations,
    }
    if deployment_name:
        body["name"] = deployment_name
    return body


def _create_deployment(
    deployment_id: str,
    directory: str,
    inputs: Dict[str, str],
    annotations: Dict[str, str],
):
    response = authed.post(
        f"{API_ROOT}/{_parent()}/deployments",
        params={"deploymentId": deployment_id, "requestId": str(uuid.uuid4())},
        json=_blueprint_body(directory, inputs, annotations),
        timeout=60,
    )
    return response, _json_or_text(response)


def _update_deployment(
    deployment_id: str,
    directory: str,
    inputs: Dict[str, str],
    annotations: Dict[str, str],
):
    response = authed.patch(
        _deployment_url(deployment_id),
        params={
            "updateMask": "terraformBlueprint,serviceAccount,annotations",
            "requestId": str(uuid.uuid4()),
        },
        json=_blueprint_body(
            directory,
            inputs,
            annotations,
            _deployment_name(deployment_id),
        ),
        timeout=60,
    )
    return response, _json_or_text(response)


def _ensure_foundation() -> Dict[str, Any]:
    existing = authed.get(_deployment_url(FOUNDATION_DEPLOYMENT_ID), timeout=30)

    if existing.status_code == 404:
        if not AUTO_CREATE_FOUNDATION:
            raise RuntimeError(
                f"{FOUNDATION_DEPLOYMENT_ID} does not exist and AUTO_CREATE_FOUNDATION=false"
            )
        response, result = _create_deployment(
            FOUNDATION_DEPLOYMENT_ID,
            FOUNDATION_TF_DIRECTORY,
            _foundation_inputs(),
            {"source": "data-model-portal", "layer": "colab-foundation"},
        )
        if not response.ok:
            raise RuntimeError(
                f"failed to create foundation deployment: {response.status_code} {result}"
            )
    elif not existing.ok:
        raise RuntimeError(
            f"failed to inspect foundation deployment: {existing.status_code} {existing.text}"
        )
    else:
        current = existing.json()
        state = current.get("state", "")
        if state == "ACTIVE":
            return current
        if state == "FAILED":
            response, result = _update_deployment(
                FOUNDATION_DEPLOYMENT_ID,
                FOUNDATION_TF_DIRECTORY,
                _foundation_inputs(),
                {"source": "data-model-portal", "layer": "colab-foundation"},
            )
            if not response.ok:
                raise RuntimeError(
                    f"failed to retry foundation deployment: {response.status_code} {result}"
                )
        elif state == "DELETING":
            raise RuntimeError("foundation deployment is deleting")

    deadline = time.monotonic() + FOUNDATION_WAIT_SECONDS
    last_state = "CREATING"
    while time.monotonic() < deadline:
        time.sleep(FOUNDATION_POLL_SECONDS)
        response = authed.get(_deployment_url(FOUNDATION_DEPLOYMENT_ID), timeout=30)
        if not response.ok:
            raise RuntimeError(
                f"failed while waiting for foundation: {response.status_code} {response.text}"
            )
        current = response.json()
        last_state = current.get("state", "UNKNOWN")
        if last_state == "ACTIVE":
            return current
        if last_state == "FAILED":
            raise RuntimeError(
                f"foundation deployment failed: {current.get('stateDetail', 'unknown error')}"
            )

    raise RuntimeError(
        f"foundation did not become ACTIVE within {FOUNDATION_WAIT_SECONDS}s; last state={last_state}"
    )


def _upsert_task(mapped: Dict[str, str]):
    deployment_id = _safe_id(mapped["task_id"], "model")
    annotations = {
        "source": "data-model-portal",
        "layer": "colab-task",
        "task-id": deployment_id,
        "group": _safe_id(mapped["group"], "group")[:20],
    }

    existing = authed.get(_deployment_url(deployment_id), timeout=30)
    if existing.status_code == 404:
        return (*_create_deployment(deployment_id, TASK_TF_DIRECTORY, mapped, annotations), "create")
    if not existing.ok:
        return None, {
            "error": "failed to inspect task deployment",
            "status": existing.status_code,
            "detail": existing.text,
        }, "inspect-error"

    current = existing.json()
    if current.get("state") in {"CREATING", "UPDATING", "DELETING"}:
        return None, {
            "error": "task deployment is busy",
            "deployment": _deployment_name(deployment_id),
            "state": current.get("state"),
        }, "busy"

    return (*_update_deployment(deployment_id, TASK_TF_DIRECTORY, mapped, annotations), "update")


@app.get("/health")
def health():
    return jsonify(
        {
            "status": "ok",
            "platform": "colab-enterprise",
            "colabProject": COLAB_PROJECT_ID,
            "location": COLAB_LOCATION,
        }
    )


@app.post("/preview")
def preview():
    payload = request.get_json(silent=False)
    if not isinstance(payload, dict):
        return jsonify({"error": "JSON object required"}), 400
    try:
        mapped = _map_portal_json(payload)
    except ValueError as exc:
        return jsonify({"error": str(exc)}), 400
    return jsonify({"mappedVariables": mapped, "foundation": _foundation_inputs()})


@app.post("/deploy")
def deploy():
    payload = request.get_json(silent=False)
    if not isinstance(payload, dict):
        return jsonify({"error": "JSON object required"}), 400

    try:
        mapped = _map_portal_json(payload)
        foundation = _ensure_foundation()
    except (ValueError, RuntimeError) as exc:
        code = 400 if isinstance(exc, ValueError) else 502
        return jsonify({"error": str(exc), "phase": "foundation-or-mapping"}), code

    response, result, action = _upsert_task(mapped)
    if response is None:
        code = 409 if action == "busy" else 502
        result["phase"] = "task"
        result["mappedVariables"] = mapped
        return jsonify(result), code

    if not response.ok:
        return jsonify(
            {
                "error": "Infrastructure Manager Colab task request failed",
                "phase": "task",
                "action": action,
                "status": response.status_code,
                "detail": result,
                "mappedVariables": mapped,
            }
        ), 502

    return jsonify(
        {
            "action": action,
            "phase": "task",
            "foundation": {
                "deployment": _deployment_name(FOUNDATION_DEPLOYMENT_ID),
                "state": foundation.get("state", "ACTIVE"),
                "platform": "colab-enterprise",
                "project": COLAB_PROJECT_ID,
                "location": COLAB_LOCATION,
            },
            "deployment": _deployment_name(_safe_id(mapped["task_id"], "model")),
            "operation": result.get("name"),
            "mappedVariables": mapped,
            "infrastructureManagerResponse": result,
        }
    ), 202


@app.get("/status")
def status():
    operation = request.args.get("operation", "").strip()
    if not operation:
        return jsonify({"error": "operation query parameter is required"}), 400
    operation = operation.removeprefix("https://config.googleapis.com/v1/").lstrip("/")
    if "/operations/" not in operation:
        return jsonify({"error": "invalid Infrastructure Manager operation name"}), 400
    response = authed.get(f"{API_ROOT}/{operation}", timeout=30)
    return jsonify(_json_or_text(response)), response.status_code


@app.get("/deployments/<deployment_id>")
def deployment_status(deployment_id: str):
    deployment_id = _safe_id(deployment_id, "model")
    response = authed.get(_deployment_url(deployment_id), timeout=30)
    return jsonify(_json_or_text(response)), response.status_code


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.getenv("PORT", "8080")))
