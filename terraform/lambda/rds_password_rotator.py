"""rds_password_rotator.py

Secrets Manager 회전 hook - RDS master 비밀번호 동기화.

AWS Secrets Manager 의 회전 trigger 4단계 (`createSecret` / `setSecret` /
`testSecret` / `finishSecret`) 를 처리한다. setSecret 단계에서 RDS 의
master_user_password 를 새 password 로 동기화하여 회전 후 RDS 가 즉시
새 비밀번호로 인증되도록 한다.

본 Lambda 의 트리거
------------------
Secrets Manager Console → secret iconia/${env}/db/master_password 의
"Rotation" 활성 시 본 Lambda 의 ARN 을 지정.

본 Lambda 가 가정하는 secret schema
----------------------------------
JSON { "username": "iconia_admin", "password": "<...>" }

EC2 측 동기화
------------
ec2-pull-and-restart.sh 의 inject_database_url 가 매 배포마다 Secrets Manager
에서 비밀번호를 다시 fetch 하므로, 회전 후 다음 deploy 또는 EC2 instance reboot
시 자동으로 새 비밀번호 사용. 운영자는 회전 직후 `trigger-deploy.ps1 -Service all`
을 한 번 발사해 strict sync 보장.

회전 4단계 동작
--------------
1) createSecret   : pending secret 이 없으면 새 password 생성하고 AWSPENDING 저장.
2) setSecret      : RDS master_user_password 를 AWSPENDING 값으로 modify-db-instance.
3) testSecret     : pending 비밀번호로 RDS 연결 시도 (psycopg2 의존성을 피하려고
                    rds describe-db-instances + AWS API ping 으로 대체. 실제 SQL
                    connect 가 필요하면 운영자가 testSecret 단계를 별도 Lambda 로
                    분리 권장).
4) finishSecret   : AWSPENDING → AWSCURRENT staging label 이동. 회전 완료.

환경 변수
--------
RDS_INSTANCE_IDENTIFIER  - 회전 대상 RDS DB instance id.
PASSWORD_LENGTH          - 신규 비밀번호 길이 (default 32).
"""

from __future__ import annotations

import json
import logging
import os
import secrets
import string
import time
from typing import Any

import boto3
from botocore.exceptions import ClientError

LOG = logging.getLogger()
LOG.setLevel(os.environ.get("LOG_LEVEL", "INFO"))

RDS_INSTANCE_IDENTIFIER = os.environ["RDS_INSTANCE_IDENTIFIER"]
PASSWORD_LENGTH = int(os.environ.get("PASSWORD_LENGTH", "32"))
# RDS password 에 허용되는 문자 - URL 인코딩 친화적이고 셸 안전.
# seed-db-password.ps1 와 같은 정책 (`$` 제거 직후 의 알파벳).
PASSWORD_ALPHABET = string.ascii_letters + string.digits + "-_."


def _generate_password() -> str:
    return "".join(secrets.choice(PASSWORD_ALPHABET) for _ in range(PASSWORD_LENGTH))


def _get_secret_value(client, secret_id: str, stage: str, version_id: str | None = None) -> dict[str, Any]:
    kwargs: dict[str, Any] = {"SecretId": secret_id, "VersionStage": stage}
    if version_id:
        kwargs["VersionId"] = version_id
    response = client.get_secret_value(**kwargs)
    return json.loads(response["SecretString"])


def create_secret(client, secret_id: str, token: str) -> None:
    # 이미 AWSPENDING 이 있으면 skip (회전 retry 안전).
    try:
        client.get_secret_value(SecretId=secret_id, VersionId=token, VersionStage="AWSPENDING")
        LOG.info("createSecret: AWSPENDING 이미 존재 (token=%s)", token)
        return
    except ClientError as e:
        if e.response["Error"]["Code"] != "ResourceNotFoundException":
            raise

    current = _get_secret_value(client, secret_id, "AWSCURRENT")
    new_password = _generate_password()
    pending = {
        "username": current["username"],
        "password": new_password,
    }
    client.put_secret_value(
        SecretId=secret_id,
        ClientRequestToken=token,
        SecretString=json.dumps(pending),
        VersionStages=["AWSPENDING"],
    )
    LOG.info("createSecret: 신규 password 저장 AWSPENDING (token=%s)", token)


def set_secret(client, secret_id: str, token: str) -> None:
    pending = _get_secret_value(client, secret_id, "AWSPENDING", version_id=token)
    new_password = pending["password"]

    rds = boto3.client("rds")
    LOG.info("setSecret: RDS modify-db-instance 호출 (instance=%s)", RDS_INSTANCE_IDENTIFIER)
    rds.modify_db_instance(
        DBInstanceIdentifier=RDS_INSTANCE_IDENTIFIER,
        MasterUserPassword=new_password,
        ApplyImmediately=True,
    )

    # modify-db-instance 는 비동기 - 짧게 대기 (실제 적용까지는 분 단위지만,
    # testSecret 의 wait loop 가 처리).
    LOG.info("setSecret: 비밀번호 modify 요청 완료 - RDS 측 적용은 비동기")


def test_secret(client, secret_id: str, token: str) -> None:
    # 실제 psycopg2 connect 는 본 Lambda 의존성을 키우므로 RDS 상태만 ping.
    # 좀 더 strict 한 테스트가 필요하면 별도 Lambda layer + psycopg2 binary 권장.
    rds = boto3.client("rds")
    deadline = time.time() + 240  # modify-db-instance 적용까지 ~4분 대기.
    while time.time() < deadline:
        resp = rds.describe_db_instances(DBInstanceIdentifier=RDS_INSTANCE_IDENTIFIER)
        status = resp["DBInstances"][0]["DBInstanceStatus"]
        if status == "available":
            LOG.info("testSecret: RDS available - 회전 적용 완료로 간주")
            return
        LOG.info("testSecret: RDS status=%s - 대기", status)
        time.sleep(15)
    raise RuntimeError(
        f"testSecret: RDS {RDS_INSTANCE_IDENTIFIER} 가 timeout 안에 available 로 복귀 안 함"
    )


def finish_secret(client, secret_id: str, token: str) -> None:
    metadata = client.describe_secret(SecretId=secret_id)
    current_version = None
    for version_id, stages in metadata["VersionIdsToStages"].items():
        if "AWSCURRENT" in stages:
            current_version = version_id
            break
    if current_version == token:
        LOG.info("finishSecret: 이미 AWSCURRENT 가 token 과 일치 - no-op")
        return

    client.update_secret_version_stage(
        SecretId=secret_id,
        VersionStage="AWSCURRENT",
        MoveToVersionId=token,
        RemoveFromVersionId=current_version,
    )
    LOG.info("finishSecret: AWSCURRENT 이동 완료 (new token=%s, old=%s)", token, current_version)


def lambda_handler(event: dict, context) -> None:  # noqa: ANN001
    secret_id = event["SecretId"]
    token = event["ClientRequestToken"]
    step = event["Step"]
    LOG.info("rotation step=%s secret=%s token=%s", step, secret_id, token)

    client = boto3.client("secretsmanager")

    # Pre-check: rotation 이 활성 + 본 version 이 회전 대상인지 확인.
    metadata = client.describe_secret(SecretId=secret_id)
    if not metadata.get("RotationEnabled"):
        raise RuntimeError(f"rotation 비활성: secret={secret_id}")
    versions = metadata.get("VersionIdsToStages", {})
    if token not in versions:
        # createSecret 단계에서는 PutSecretValue 가 아직 안 일어났을 수 있음 - 정상.
        if step != "createSecret":
            raise RuntimeError(f"token {token} 가 secret 의 알려진 version 이 아님")

    if step == "createSecret":
        create_secret(client, secret_id, token)
    elif step == "setSecret":
        set_secret(client, secret_id, token)
    elif step == "testSecret":
        test_secret(client, secret_id, token)
    elif step == "finishSecret":
        finish_secret(client, secret_id, token)
    else:
        raise ValueError(f"unknown rotation step: {step}")
