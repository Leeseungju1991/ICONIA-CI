"""gcp_quotas_auto_lift.py

GCP Cloud Quotas 자동 증설 신청 Lambda (Round 2026-05-26, Task #11).

배경
----
Gemini API 트래픽 폭주(예: 인플루언서 노출로 인한 가입 급증 — Phase 5 #20 retro)
시 generate_content_requests_per_minute_per_project 가 모자라 fallback 폭증.
Google Cloud Quotas API 로 quota 증설 신청을 자동화하면, 운영자가 알람을
받고 콘솔에서 폼을 채우는 30~60분 지연을 cron 으로 사전 완충.

본 라운드는 **준비 코드**다. 실제 활성화는 운영자가 EventBridge cron 의
state 를 ENABLED 로 바꾸고 GCP service account JSON 을 Secrets Manager 에
주입한 뒤 발사한다 (terraform.tfvars 의 enable_quotas_auto_lift=true).

전략
----
* 주간 cron (Sunday 00:00 UTC).
* 현재 quota 의 effective limit 을 조회 → baseline 의 200% 로 증설 신청.
* 신청 자체는 즉시 승인되지 않는다 — Google manual review (1~3 영업일).
  rejected 되더라도 본 Lambda 는 다음 주에 재신청 (멱등 — 같은 limit_value
  요청은 GCP 가 중복 신청으로 dedupe).
* 결과는 CloudWatch Logs + CloudWatch metric (QuotasAutoLiftRequested) 로
  관측. SNS 알람 토픽이 Slack 으로 forward (alarms.tf 정합).

대상 quota
----------
generativelanguage.googleapis.com / generate_content_requests_per_minute_per_project

(추후 확장 후보)
- generate_content_input_tokens_per_minute_per_project
- generate_content_tokens_per_day_per_project_per_model

환경변수 (terraform 이 inject)
-----------------------------
GCP_PROJECT_ID         : GCP project id (예: iconia-prod-457912).
GCP_SA_SECRET_NAME     : Secrets Manager 의 service account JSON secret 이름.
                         (iconia/${env}/gcp/service_account_json 형식 권장).
QUOTA_TARGET_LIMIT_NAME: API 의 limit name (예:
                         GenerateContentRequestsPerMinutePerProject).
QUOTA_MULTIPLIER       : baseline → 신청값 배수 (기본 "2" = 200%).
QUOTA_HARD_CEILING     : 최종 안전 상한 (기본 "10000"). 절대 이 값을 넘기지 않음.
LOG_LEVEL              : INFO|DEBUG.

본 Lambda 가 호출하는 GCP API
-----------------------------
1) cloudquotas.googleapis.com:
   GET  /v1/projects/${PROJECT}/locations/global/services/generativelanguage.googleapis.com/quotaInfos/${LIMIT_NAME}
     → 현재 quotaInfo (effective 한계 + dimension 별 분포).
   POST /v1/projects/${PROJECT}/locations/global/services/.../quotaPreferences
     body: { name, dimensions, quotaConfig: { preferredValue: N }, ...}
     → quota increase 신청 row 생성. Google 측 manual review.

자동 승인 한계
-------------
- Cloud Quotas API 의 자동 증설 (cooldown) 은 일부 quota 에만 적용.
  generate_content_requests_per_minute_per_project 는 manual review (1~3 영업일).
- 본 Lambda 는 신청만 트리거 — 운영자가 polling /
  https://console.cloud.google.com/iam-admin/quotas 에서 상태 확인 필요.

비용
----
- Lambda invocation: 주간 1회 → 월 4회 → 무료 free tier 안.
- Secrets Manager API call: ~1회/주 → 무시 가능.
- GCP Cloud Quotas API: 무료.

IAM 권한 (AWS side)
-------------------
- secretsmanager:GetSecretValue (GCP_SA_SECRET_NAME 1개).
- logs:* (CloudWatch Logs).
- cloudwatch:PutMetricData (Namespace ICONIA/Quotas).

권한 (GCP side)
---------------
service account 가 다음 role 보유 필요:
- roles/cloudquotas.admin (또는 roles/cloudquotas.viewer + custom).
"""
import json
import logging
import os
import sys

# 외부 의존성 — Lambda layer 또는 zip 동봉 필요:
#   google-auth, google-auth-httplib2, google-api-python-client 또는 직접 google-cloud-quotas SDK.
# 본 라운드는 import 자체를 try/except 로 감싸 "준비 only" 상태에서 부팅 가능하게 한다.
try:
    import boto3  # type: ignore
    from google.oauth2 import service_account  # type: ignore
    from google.auth.transport.requests import AuthorizedSession  # type: ignore
    _IMPORTS_OK = True
    _IMPORT_ERROR = None
except Exception as exc:  # noqa: BLE001
    _IMPORTS_OK = False
    _IMPORT_ERROR = str(exc)

logger = logging.getLogger()
logger.setLevel(os.environ.get("LOG_LEVEL", "INFO"))

CLOUDQUOTAS_BASE = "https://cloudquotas.googleapis.com/v1"
SERVICE = "generativelanguage.googleapis.com"


def _load_service_account_json(secret_name: str) -> dict:
    """Secrets Manager 에서 GCP service account JSON 을 조회 → dict 반환."""
    client = boto3.client("secretsmanager")
    resp = client.get_secret_value(SecretId=secret_name)
    raw = resp.get("SecretString") or ""
    if not raw:
        raise RuntimeError(f"secret {secret_name} has no SecretString")
    return json.loads(raw)


def _build_session(sa_info: dict) -> "AuthorizedSession":
    creds = service_account.Credentials.from_service_account_info(
        sa_info,
        scopes=["https://www.googleapis.com/auth/cloud-platform"],
    )
    return AuthorizedSession(creds)


def _get_current_quota(session, project_id: str, limit_name: str) -> dict:
    """GET quotaInfos/${limit_name}."""
    url = (
        f"{CLOUDQUOTAS_BASE}/projects/{project_id}/locations/global/services/"
        f"{SERVICE}/quotaInfos/{limit_name}"
    )
    r = session.get(url, timeout=15)
    r.raise_for_status()
    return r.json()


def _request_quota_increase(
    session, project_id: str, limit_name: str, preferred_value: int, justification: str
) -> dict:
    """POST quotaPreferences — quota 증설 신청 row 생성."""
    url = (
        f"{CLOUDQUOTAS_BASE}/projects/{project_id}/locations/global/services/"
        f"{SERVICE}/quotaPreferences"
    )
    body = {
        "quotaConfig": {"preferredValue": str(preferred_value)},
        "justification": justification,
        # dimensions 미지정 = 전역 (per-project) 변경. region 별 quota 가 필요하면 추가.
    }
    r = session.post(url, json=body, timeout=30)
    # 409 = 이미 동일 preferred_value 의 pending preference 존재 → 무해 (멱등).
    if r.status_code == 409:
        logger.info("quota_preference_already_pending preferred_value=%s", preferred_value)
        return {"ok": True, "deduped": True, "status": 409}
    r.raise_for_status()
    return {"ok": True, "deduped": False, "status": r.status_code, "body": r.json()}


def _publish_metric(metric_name: str, value: float, unit: str = "Count") -> None:
    """CloudWatch ICONIA/Quotas 네임스페이스로 결과 게이지 송출."""
    try:
        cw = boto3.client("cloudwatch")
        cw.put_metric_data(
            Namespace="ICONIA/Quotas",
            MetricData=[{"MetricName": metric_name, "Value": float(value), "Unit": unit}],
        )
    except Exception as exc:  # noqa: BLE001
        logger.warning("metric_publish_failed metric=%s err=%s", metric_name, exc)


def lambda_handler(event, _context):
    """EventBridge cron payload 는 비어 있음. event 는 무시."""
    if not _IMPORTS_OK:
        logger.error("imports_failed err=%s", _IMPORT_ERROR)
        _publish_metric("QuotasAutoLiftError", 1)
        return {"ok": False, "reason": "imports_failed", "error": _IMPORT_ERROR}

    project_id = os.environ.get("GCP_PROJECT_ID", "")
    secret_name = os.environ.get("GCP_SA_SECRET_NAME", "")
    limit_name = os.environ.get(
        "QUOTA_TARGET_LIMIT_NAME", "GenerateContentRequestsPerMinutePerProject"
    )
    multiplier = float(os.environ.get("QUOTA_MULTIPLIER", "2") or "2")
    hard_ceiling = int(os.environ.get("QUOTA_HARD_CEILING", "10000") or "10000")

    if not project_id or not secret_name:
        logger.error("missing_env GCP_PROJECT_ID or GCP_SA_SECRET_NAME")
        _publish_metric("QuotasAutoLiftError", 1)
        return {"ok": False, "reason": "missing_env"}

    try:
        sa_info = _load_service_account_json(secret_name)
        session = _build_session(sa_info)

        current = _get_current_quota(session, project_id, limit_name)
        # quotaInfo schema (요약):
        #   { name, quotaId, dimensions:[...], dimensionsInfos:[{ details:{ value:'N' } }] }
        # baseline 추출 — 첫 dimensionsInfos.details.value 사용. quota 가 region 별로 갈리면
        # 본 단순 구현은 첫 dimension 만 본다. (운영자가 필요시 확장)
        dim_infos = current.get("dimensionsInfos", []) or []
        baseline_str = "0"
        if dim_infos:
            baseline_str = str(dim_infos[0].get("details", {}).get("value") or "0")
        try:
            baseline = int(baseline_str)
        except ValueError:
            baseline = 0
        if baseline <= 0:
            logger.warning("baseline_unknown limit=%s response=%s", limit_name, current)
            _publish_metric("QuotasAutoLiftError", 1)
            return {"ok": False, "reason": "baseline_unknown"}

        requested = min(int(baseline * multiplier), hard_ceiling)
        if requested <= baseline:
            logger.info("requested_<=baseline — no-op baseline=%s requested=%s", baseline, requested)
            _publish_metric("QuotasAutoLiftNoop", 1)
            return {"ok": True, "noop": True, "baseline": baseline}

        result = _request_quota_increase(
            session,
            project_id,
            limit_name,
            requested,
            justification=(
                f"ICONIA weekly auto-lift: baseline={baseline}, requested={requested} "
                f"(multiplier={multiplier}). Google manual review may take 1-3 business days."
            ),
        )
        _publish_metric("QuotasAutoLiftRequested", 1)
        logger.info(
            "quota_increase_requested baseline=%s requested=%s deduped=%s",
            baseline,
            requested,
            result.get("deduped"),
        )
        return {"ok": True, "baseline": baseline, "requested": requested, **result}

    except Exception as exc:  # noqa: BLE001
        logger.error("quotas_auto_lift_failed err=%s", exc, exc_info=True)
        _publish_metric("QuotasAutoLiftError", 1)
        return {"ok": False, "reason": "exception", "error": str(exc)}


if __name__ == "__main__":  # 로컬 디버그용
    print(json.dumps(lambda_handler({}, None), indent=2))
    sys.exit(0)
