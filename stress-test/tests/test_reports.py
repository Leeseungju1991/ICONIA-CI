"""Report generator 검증."""
from pathlib import Path
import json
import tempfile
from reports.generator import compute_stats, percentile, detect_bottlenecks, write_csv, generate_reports


def test_percentile_basic():
    assert percentile([1, 2, 3, 4, 5], 50) == 3
    assert percentile([], 50) == 0


def test_compute_stats_empty():
    s = compute_stats([])
    assert s["total"] == 0
    assert s["p95_s"] == 0


def test_compute_stats_with_results():
    results = [
        {"ok": True, "latency_s": 0.1, "target": "server", "status": 200, "pattern": "normal"},
        {"ok": True, "latency_s": 0.2, "target": "server", "status": 200, "pattern": "normal"},
        {"ok": False, "latency_s": 0.5, "target": "ai", "status": 500, "pattern": "malformed"},
    ]
    s = compute_stats(results)
    assert s["total"] == 3
    assert s["ok"] == 2
    assert s["failed"] == 1
    assert "server" in s["by_target_count"]
    assert s["by_status"]["200"] == 2


def test_bottleneck_detection_p99():
    stats = {"p99_s": 6.0, "failed": 1, "total": 100, "by_status": {}, "by_target_count": {}}
    bots = detect_bottlenecks(stats, [])
    assert any("p99" in b for b in bots)


def test_bottleneck_detection_429():
    stats = {"p99_s": 1.0, "failed": 1, "total": 100, "by_status": {"429": 50}, "by_target_count": {}}
    bots = detect_bottlenecks(stats, [])
    assert any("429" in b for b in bots)


def test_write_csv_basic():
    with tempfile.TemporaryDirectory() as d:
        out = write_csv(Path(d), [
            {"event_id": "abc", "event_type": "feed.list", "pattern": "normal",
             "target": "server", "status": 200, "ok": True, "latency_s": 0.1},
        ])
        assert out.exists()
        content = out.read_text(encoding="utf-8")
        assert "feed.list" in content
        assert "server" in content


def test_generate_html_report():
    with tempfile.TemporaryDirectory() as d:
        out_dir = Path(d)
        summary = {"pattern": "steady", "rps": 100, "duration_s": 60,
                   "started_at": "2026-05-28T00:00:00Z", "ended_at": "2026-05-28T00:01:00Z"}
        results = [{"ok": True, "latency_s": 0.1, "target": "server", "status": 200,
                    "event_id": "abc", "event_type": "feed.list", "pattern": "normal"}]
        (out_dir / "summary.json").write_text(json.dumps(summary))
        generate_reports(out_dir, summary, results)
        assert (out_dir / "report.html").exists()
        assert (out_dir / "stats.json").exists()
        assert (out_dir / "requests.csv").exists()
        html = (out_dir / "report.html").read_text(encoding="utf-8")
        assert "ICONIA Stress Test Report" in html
