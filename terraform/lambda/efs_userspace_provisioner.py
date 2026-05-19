"""efs_userspace_provisioner.py

EFS per-user access point provisioner Lambda.

발사 경로
---------
1) SNS topic `iconia-${env}-user-events` (Server 회원가입/탈퇴 시 publish)
   - 메시지 형식: {"event": "user.created" | "user.deleted", "user_id": "<uuid>"}
2) EventBridge schedule (보정용. SNS 미수신 user 를 매시간 catch-up)
   - 페이로드: {"event": "user.reconcile", "user_ids": ["<uuid>", ...]}

동작
----
- user.created: aws_efs_access_point 가 없으면 새로 만들고 user 식별자를 Name 태그에 저장.
  POSIX uid/gid 는 USER_ID_BASE + hash(user_id) mod USER_ID_SPACE 로 결정성 유지
  (재실행 시 같은 user_id 는 같은 uid). 충돌은 사용자 수가 USER_ID_SPACE / 1000 미만이면
  실제로 발생하지 않으나 안전을 위해 충돌 감지 시 +1 재시도 (최대 10회) 후 alarm.
  root_directory.path 는 `/iconia/<user_id>` (서버 코드의 storage prefix 와 1:1 매핑).
- user.deleted: access point 삭제(EFS 데이터는 lifecycle 에서 별도 처리. AP 자체만 회수).
- user.reconcile: 입력된 user_id 목록을 전부 user.created 와 동일하게 idempotent 처리.

설계 노트
--------
- 본 Lambda 는 P0 격리의 "장기" 해결책. 단기 워크어라운드로 AI 측이 path.startsWith
  가드를 갖는다 (persona-ai 측 별도 PR). 둘 다 운영해도 무해 - 가드는 코드 레벨,
  AP 는 커널 레벨 격리.
- 본 Lambda 는 access point 만 생성한다. EFS 디렉토리 (mkdir /iconia/<user_id>) 는
  AP 의 creation_info.owner_uid/gid + permissions 가 EFS 측에서 자동 처리.
- terraform 으로 본 Lambda 를 배포한 직후엔 기존 가입자 백필 필요:
  운영자가 `aws lambda invoke --function-name iconia-${env}-efs-userspace-provisioner
  --payload '{"event":"user.reconcile","user_ids":[...]}' /tmp/out.json` 수동 호출.

환경 변수 (terraform 측에서 주입)
--------------------------------
- EFS_FILE_SYSTEM_ID
- ICONIA_ENV
- USER_ID_BASE (default "1000")
- USER_ID_SPACE (default "1000000")
- LOG_LEVEL (default "INFO")
"""

from __future__ import annotations

import hashlib
import json
import logging
import os
from typing import Iterable

import boto3
from botocore.exceptions import ClientError

LOG = logging.getLogger()
LOG.setLevel(os.environ.get("LOG_LEVEL", "INFO"))

EFS_FILE_SYSTEM_ID = os.environ["EFS_FILE_SYSTEM_ID"]
ICONIA_ENV = os.environ.get("ICONIA_ENV", "prod")
USER_ID_BASE = int(os.environ.get("USER_ID_BASE", "1000"))
USER_ID_SPACE = int(os.environ.get("USER_ID_SPACE", "1000000"))
MAX_COLLISION_RETRY = 10

efs = boto3.client("efs")


# ---------------------------------------------------------------------------
# 결정성 있는 uid/gid 계산.
# user_id (UUID 문자열) 를 sha256 해 정수로 변환 → mod USER_ID_SPACE.
# 가입자가 USER_ID_SPACE 의 0.1% 까지는 충돌 확률 < 0.05% (생일 문제 기준).
# 충돌 시 +1 재시도. 1000 만 단위 운영 진입 전 USER_ID_SPACE 확장 필요 (env 만 바꾸면 됨).
# ---------------------------------------------------------------------------
def _uid_for(user_id: str, attempt: int = 0) -> int:
    digest = hashlib.sha256(user_id.encode("utf-8")).digest()
    n = int.from_bytes(digest[:8], "big")
    return USER_ID_BASE + ((n + attempt) % USER_ID_SPACE)


def _existing_access_point(user_id: str) -> dict | None:
    """user_id Name 태그를 가진 AP 를 찾는다. 없으면 None."""
    paginator = efs.get_paginator("describe_access_points")
    for page in paginator.paginate(FileSystemId=EFS_FILE_SYSTEM_ID):
        for ap in page.get("AccessPoints", []):
            tags = {t["Key"]: t["Value"] for t in ap.get("Tags", [])}
            if tags.get("iconia:user_id") == user_id:
                return ap
    return None


def _uid_in_use(uid: int) -> bool:
    paginator = efs.get_paginator("describe_access_points")
    for page in paginator.paginate(FileSystemId=EFS_FILE_SYSTEM_ID):
        for ap in page.get("AccessPoints", []):
            posix = ap.get("PosixUser") or {}
            if posix.get("Uid") == uid:
                return True
    return False


def _ensure_access_point(user_id: str) -> dict:
    existing = _existing_access_point(user_id)
    if existing:
        LOG.info("AP 이미 존재 user_id=%s ap_id=%s", user_id, existing["AccessPointId"])
        return existing

    uid = _uid_for(user_id)
    for attempt in range(MAX_COLLISION_RETRY):
        candidate = _uid_for(user_id, attempt)
        if not _uid_in_use(candidate):
            uid = candidate
            break
    else:
        # 충돌이 MAX_COLLISION_RETRY 까지 이어지는 건 USER_ID_SPACE 가 작거나 해시 문제.
        # 운영자가 USER_ID_SPACE 확장 결정해야 함.
        raise RuntimeError(
            f"uid collision retry exhausted for user_id={user_id}. "
            "USER_ID_SPACE 확장 필요."
        )

    LOG.info("AP 생성 user_id=%s uid=%d", user_id, uid)
    response = efs.create_access_point(
        ClientToken=f"iconia-{ICONIA_ENV}-{user_id}",
        FileSystemId=EFS_FILE_SYSTEM_ID,
        PosixUser={"Uid": uid, "Gid": uid},
        RootDirectory={
            "Path": f"/iconia/{user_id}",
            "CreationInfo": {
                "OwnerUid": uid,
                "OwnerGid": uid,
                "Permissions": "0700",
            },
        },
        Tags=[
            {"Key": "iconia:user_id", "Value": user_id},
            {"Key": "iconia:env", "Value": ICONIA_ENV},
            {"Key": "Name", "Value": f"iconia-{ICONIA_ENV}-userspace-{user_id}"},
            {"Key": "managed_by", "Value": "iconia-efs-userspace-provisioner"},
        ],
    )
    return response


def _delete_access_point(user_id: str) -> None:
    existing = _existing_access_point(user_id)
    if not existing:
        LOG.info("delete: AP 없음 (no-op) user_id=%s", user_id)
        return
    ap_id = existing["AccessPointId"]
    LOG.info("AP 삭제 user_id=%s ap_id=%s", user_id, ap_id)
    try:
        efs.delete_access_point(AccessPointId=ap_id)
    except ClientError as e:
        # AP 삭제 실패는 보통 AP 사용 중 mount. 운영자 alarm.
        LOG.error("AP 삭제 실패 user_id=%s ap_id=%s err=%s", user_id, ap_id, e)
        raise


# ---------------------------------------------------------------------------
# Event 디스패처. SNS 와 EventBridge 모두 본 함수가 수신.
# ---------------------------------------------------------------------------
def _iter_messages(event: dict) -> Iterable[dict]:
    if "Records" in event:
        for rec in event["Records"]:
            sns = rec.get("Sns") or {}
            msg = sns.get("Message")
            if msg:
                try:
                    yield json.loads(msg)
                except json.JSONDecodeError:
                    LOG.warning("SNS message JSON 파싱 실패 - skip: %s", msg)
    else:
        yield event


def lambda_handler(event: dict, context) -> dict:  # noqa: ANN001 - aws lambda signature
    LOG.debug("event=%s", json.dumps(event)[:2000])
    created, deleted, reconciled = 0, 0, 0

    for msg in _iter_messages(event):
        kind = msg.get("event")
        if kind == "user.created":
            user_id = msg["user_id"]
            _ensure_access_point(user_id)
            created += 1
        elif kind == "user.deleted":
            user_id = msg["user_id"]
            _delete_access_point(user_id)
            deleted += 1
        elif kind == "user.reconcile":
            for uid in msg.get("user_ids", []):
                _ensure_access_point(uid)
                reconciled += 1
        else:
            LOG.warning("unknown event kind: %s (skip)", kind)

    summary = {"created": created, "deleted": deleted, "reconciled": reconciled}
    LOG.info("done %s", summary)
    return summary
