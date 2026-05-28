"""Virtual Event Simulator pytest 검증."""
import asyncio
import pytest
from simulator.virtual_events import VirtualEventSimulator, SimulatorConfig, EventPattern
from simulator.event_types import EventType


def test_simulator_init():
    sim = VirtualEventSimulator(SimulatorConfig(target_rps=10, duration_s=1))
    assert sim.cfg.target_rps == 10


def test_make_event_normal():
    sim = VirtualEventSimulator()
    evt = sim._make_event(EventPattern.NORMAL)
    assert evt.event_id
    assert evt.event_type
    assert evt.pattern == "normal"
    assert evt.user_id and evt.device_id


def test_malformed_payload():
    sim = VirtualEventSimulator()
    evt = sim._make_event(EventPattern.MALFORMED)
    assert evt.pattern == "malformed"
    assert "__malformed__" in evt.payload


def test_abnormal_payload():
    sim = VirtualEventSimulator()
    evt = sim._make_event(EventPattern.ABNORMAL)
    assert evt.payload.get("negative_count") == -999


def test_no_hw_events():
    """CMD §4-2: BLE/Wi-Fi/touch/image 이벤트 절대 생성 X"""
    sim = VirtualEventSimulator()
    for _ in range(100):
        evt = sim._make_event(EventPattern.NORMAL)
        assert "ble" not in evt.event_type.lower()
        assert "wifi" not in evt.event_type.lower()
        assert "touch" not in evt.event_type.lower()
        assert "image" not in evt.event_type.lower()
        assert "firmware_packet" not in evt.event_type.lower()


@pytest.mark.asyncio
async def test_stream_finite():
    sim = VirtualEventSimulator(SimulatorConfig(target_rps=50, duration_s=1))
    count = 0
    async for _ in sim.stream():
        count += 1
        if count > 200:
            break
    assert count > 0


def test_make_burst():
    sim = VirtualEventSimulator()
    burst = sim.make_burst(50)
    assert len(burst) == 50
    assert all(e.pattern == "normal" for e in burst)


def test_pattern_distribution():
    """약 70% 가 normal — config 비율 검증."""
    sim = VirtualEventSimulator()
    counts = {p: 0 for p in EventPattern}
    for _ in range(1000):
        pat = sim._pick_pattern()
        counts[pat] += 1
    assert counts[EventPattern.NORMAL] / 1000 > 0.5  # 약 70%
