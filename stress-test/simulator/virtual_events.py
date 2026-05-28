"""Virtual Event Simulator — 12 패턴 이벤트 생성.

CMD §4-1 의 12 패턴:
    normal, duplicate, delayed, out_of_order, malformed, missing, burst,
    reconnect, timeout, retry, abnormal_state, (+ large)

CMD §4-2 의 제외 이벤트 (BLE/Wi-Fi/터치/이미지/firmware) 는 절대 생성 X.
"""
from __future__ import annotations

import asyncio
import random
import time
import uuid
from enum import Enum
from dataclasses import dataclass
from typing import AsyncIterator, Optional

from .event_types import EventType, EventPayload


class EventPattern(str, Enum):
    NORMAL = "normal"
    DUPLICATE = "duplicate"
    DELAYED = "delayed"
    OUT_OF_ORDER = "out_of_order"
    MALFORMED = "malformed"
    MISSING = "missing"
    BURST = "burst"
    RECONNECT = "reconnect"
    TIMEOUT = "timeout"
    RETRY = "retry"
    ABNORMAL = "abnormal_state"
    LARGE = "large"


@dataclass
class SimulatorConfig:
    target_rps: int = 100
    duration_s: int = 300
    # 패턴 별 비율 (합 = 1.0)
    normal_ratio: float = 0.70
    duplicate_ratio: float = 0.05
    malformed_ratio: float = 0.05
    out_of_order_ratio: float = 0.05
    timeout_ratio: float = 0.05
    burst_ratio: float = 0.05
    reconnect_ratio: float = 0.03
    abnormal_ratio: float = 0.02


class VirtualEventSimulator:
    """HW 의존 이벤트 제외, 12 패턴으로 이벤트 생성."""

    def __init__(self, cfg: SimulatorConfig | None = None) -> None:
        self.cfg = cfg or SimulatorConfig()
        self._seq = 0
        self._user_pool = [f"user-{i:04d}" for i in range(100)]
        self._device_pool = [f"dev-{i:04d}" for i in range(50)]
        self._seen_event_ids: set[str] = set()

    def _pick_pattern(self) -> EventPattern:
        r = random.random()
        c = self.cfg
        cumulative = [
            (c.normal_ratio, EventPattern.NORMAL),
            (c.duplicate_ratio, EventPattern.DUPLICATE),
            (c.out_of_order_ratio, EventPattern.OUT_OF_ORDER),
            (c.malformed_ratio, EventPattern.MALFORMED),
            (c.timeout_ratio, EventPattern.TIMEOUT),
            (c.burst_ratio, EventPattern.BURST),
            (c.reconnect_ratio, EventPattern.RECONNECT),
            (c.abnormal_ratio, EventPattern.ABNORMAL),
        ]
        acc = 0.0
        for ratio, pat in cumulative:
            acc += ratio
            if r < acc:
                return pat
        return EventPattern.NORMAL

    def _pick_event_type(self) -> EventType:
        # 사용 빈도 가중치 (실 운영 패턴)
        weights = [
            (EventType.FEED_LIST, 30),
            (EventType.AI_CHAT_REQUEST, 20),
            (EventType.COMMERCE_LIST, 15),
            (EventType.USER_LOGIN, 8),
            (EventType.USER_REFRESH, 8),
            (EventType.FEED_POST_GET, 7),
            (EventType.DEVICE_HEARTBEAT, 5),
            (EventType.ADMIN_USERS_SEARCH, 3),
            (EventType.FEED_COMMENT_CREATE, 2),
            (EventType.AI_PERSONA_QUERY, 1),
            (EventType.ADMIN_AUDIT_LIST, 1),
        ]
        total = sum(w for _, w in weights)
        r = random.uniform(0, total)
        acc = 0
        for et, w in weights:
            acc += w
            if r < acc:
                return et
        return EventType.FEED_LIST

    def _make_event(self, pattern: EventPattern) -> EventPayload:
        et = self._pick_event_type()
        user_id = random.choice(self._user_pool)
        device_id = random.choice(self._device_pool)
        evt = EventPayload(
            event_type=et.value,
            user_id=user_id,
            device_id=device_id,
            pattern=pattern.value,
            payload=self._build_payload(et, pattern),
        )
        self._seq += 1
        # 중복 추적
        if pattern == EventPattern.DUPLICATE and self._seen_event_ids:
            evt.event_id = random.choice(list(self._seen_event_ids)[-50:])
        else:
            self._seen_event_ids.add(evt.event_id)
            if len(self._seen_event_ids) > 1000:
                # 메모리 가드
                self._seen_event_ids = set(list(self._seen_event_ids)[-500:])
        # malformed 는 의도적으로 깨진 payload
        if pattern == EventPattern.MALFORMED:
            evt.payload = {"__malformed__": "true", "random_bytes": "\x00\xff\x7f"}
        # abnormal: 비정상적 값
        if pattern == EventPattern.ABNORMAL:
            evt.payload["negative_count"] = -999
            evt.payload["impossible_timestamp"] = 0
        # large: 큰 payload
        if pattern == EventPattern.LARGE:
            evt.payload["large_text"] = "x" * 100_000
        return evt

    def _build_payload(self, et: EventType, pat: EventPattern) -> dict:
        if et == EventType.FEED_POST_CREATE:
            return {"content": f"stress-test post {self._seq}", "media": []}
        if et == EventType.FEED_LIST:
            return {"page": random.randint(1, 5), "page_size": 25}
        if et == EventType.AI_CHAT_REQUEST:
            prompts = [
                "안녕! 오늘 기분 어때?",
                "오늘 뭐 했어? 짧게 알려줘.",
                "내가 좋아하는 음악 추천해줄래?",
                "1년 후에 우리는 어떻게 될까?",
                "x" * 5000,  # long prompt
            ]
            return {"prompt": random.choice(prompts), "persona_id": "aria"}
        if et == EventType.COMMERCE_LIST:
            return {"page": random.randint(1, 3), "category": random.choice([None, "인형", "의상"])}
        if et == EventType.USER_LOGIN:
            return {"email": "stress@iconia.dev", "password": "(redacted)"}
        if et == EventType.DEVICE_HEARTBEAT:
            return {"battery": random.randint(20, 100), "firmware_version": "1.0.2"}
        return {}

    async def stream(self) -> AsyncIterator[EventPayload]:
        """비동기로 이벤트 stream — target_rps 에 맞춰 sleep."""
        interval = 1.0 / max(self.cfg.target_rps, 1)
        deadline = time.time() + self.cfg.duration_s
        recent: list[EventPayload] = []
        while time.time() < deadline:
            pattern = self._pick_pattern()
            # burst — 한 번에 여러 이벤트
            if pattern == EventPattern.BURST:
                for _ in range(random.randint(5, 20)):
                    evt = self._make_event(EventPattern.NORMAL)
                    recent.append(evt)
                    yield evt
            elif pattern == EventPattern.OUT_OF_ORDER:
                evt = self._make_event(pattern)
                # 옛 타임스탬프 부여
                evt.timestamp -= random.uniform(60, 600)
                yield evt
            elif pattern == EventPattern.DELAYED:
                evt = self._make_event(pattern)
                await asyncio.sleep(random.uniform(1, 5))
                yield evt
            else:
                evt = self._make_event(pattern)
                recent.append(evt)
                yield evt
            await asyncio.sleep(interval * random.uniform(0.5, 1.5))

    def make_burst(self, count: int) -> list[EventPayload]:
        """단일 burst — count 개 즉시 생성."""
        return [self._make_event(EventPattern.NORMAL) for _ in range(count)]
