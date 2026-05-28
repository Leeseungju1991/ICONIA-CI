"""Virtual Event 스키마.

HW 제외 이벤트만 포함. BLE/Wi-Fi/터치/이미지/firmware packet 은 절대 정의 X.
"""
from __future__ import annotations

from dataclasses import dataclass, field, asdict
from enum import Enum
from typing import Any, Optional
import time
import uuid


class EventType(str, Enum):
    """본 플랫폼이 다루는 가상 이벤트 타입."""
    # 사용자 행동 (앱 → 서버)
    USER_LOGIN = "user.login"
    USER_REFRESH = "user.refresh_token"
    USER_LOGOUT = "user.logout"

    # 피드
    FEED_LIST = "feed.list"
    FEED_POST_CREATE = "feed.post.create"
    FEED_POST_GET = "feed.post.get"
    FEED_COMMENT_CREATE = "feed.comment.create"

    # 커머스 (display-only)
    COMMERCE_LIST = "commerce.list"
    COMMERCE_GET = "commerce.get"

    # AI 채팅
    AI_CHAT_REQUEST = "ai.chat.request"
    AI_PERSONA_QUERY = "ai.persona.query"

    # 운영 (ADMIN)
    ADMIN_USERS_SEARCH = "admin.users.search"
    ADMIN_AUDIT_LIST = "admin.audit.list"
    ADMIN_FEED_TAKEDOWN = "admin.feed.takedown"

    # 디바이스 (HW 비포함 — virtual 만)
    DEVICE_HEARTBEAT = "device.heartbeat"
    DEVICE_OTA_STATUS = "device.ota.status"


@dataclass
class EventPayload:
    """단일 이벤트 — JSON 직렬화 가능."""
    event_id: str = field(default_factory=lambda: str(uuid.uuid4()))
    event_type: str = ""
    user_id: Optional[str] = None
    device_id: Optional[str] = None
    payload: dict[str, Any] = field(default_factory=dict)
    timestamp: float = field(default_factory=time.time)
    pattern: str = "normal"   # 본 이벤트가 만들어진 패턴 (정상/중복/누락 등)

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)
