"""Virtual Event Simulator — HW 대체 이벤트 생성 (12 패턴).

HW 의존 이벤트(BLE/Wi-Fi/터치/이미지)는 절대 생성하지 않는다.
"""
from .virtual_events import VirtualEventSimulator, EventPattern
from .event_types import EventType, EventPayload

__all__ = ["VirtualEventSimulator", "EventPattern", "EventType", "EventPayload"]
