.PHONY: help install stress-test stress-test-steady stress-test-spike stress-test-soak stress-test-chaos report monitoring monitoring-down test clean

PYTHON ?= python
ENV_FILE := .env

help:
	@echo "ICONIA E2E Wide Stress Test"
	@echo ""
	@echo "Targets:"
	@echo "  install                Python deps + locust + k6 (option)"
	@echo "  stress-test            Default — STRESS_PATTERN 따름"
	@echo "  stress-test-steady     Steady load"
	@echo "  stress-test-spike      Spike (5min)"
	@echo "  stress-test-soak       Soak (24h — long)"
	@echo "  stress-test-chaos      Chaos injection enabled"
	@echo "  monitoring             Prometheus + Grafana + Loki + OTEL Collector"
	@echo "  monitoring-down        Stop monitoring stack"
	@echo "  report                 Generate JSON/CSV/HTML report"
	@echo "  test                   pytest validation"
	@echo "  clean                  Clean output/cache"

install:
	$(PYTHON) -m pip install -r requirements.txt || true
	@command -v locust >/dev/null 2>&1 || $(PYTHON) -m pip install locust
	@echo "k6 install: https://k6.io/docs/getting-started/installation/ (optional)"

stress-test:
	@test -f $(ENV_FILE) || (echo "❌ .env not found — cp .env.example .env" && exit 1)
	$(PYTHON) scripts/orchestrate-load.py

stress-test-steady:
	STRESS_PATTERN=steady $(MAKE) stress-test

stress-test-spike:
	STRESS_PATTERN=spike STRESS_DURATION_S=300 $(MAKE) stress-test

stress-test-soak:
	STRESS_PATTERN=soak STRESS_DURATION_S=86400 $(MAKE) stress-test

stress-test-chaos:
	STRESS_PATTERN=chaos CHAOS_ENABLED=true $(MAKE) stress-test

monitoring:
	docker compose -f docker-compose.yml up -d prometheus grafana loki otel-collector

monitoring-down:
	docker compose -f docker-compose.yml down

report:
	$(PYTHON) reports/generator.py

test:
	$(PYTHON) -m pytest tests/ -v

clean:
	rm -rf reports/output __pycache__ .pytest_cache
	find . -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
