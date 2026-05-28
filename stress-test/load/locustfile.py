"""Locust scenario — AWS 부하 worker 대안.

사용:
  locust -f load/locustfile.py --host=$STAGING_SERVER_BASE --users 100 --spawn-rate 10
"""
from locust import HttpUser, task, between, events
import os
import random


class ICONIAUser(HttpUser):
    wait_time = between(0.1, 1.0)

    def on_start(self) -> None:
        token = os.getenv("STRESS_JWT_TOKEN")
        if token:
            self.client.headers["Authorization"] = f"Bearer {token}"
        self.client.headers["User-Agent"] = "ICONIA-Locust/1.0"

    @task(30)
    def feed_list(self) -> None:
        self.client.get("/api/v1/admin/feed/posts?page=1&page_size=25", name="feed.list")

    @task(15)
    def commerce_list(self) -> None:
        self.client.get("/api/v1/admin/commerce/products?page=1&page_size=50", name="commerce.list")

    @task(20)
    def ai_chat(self) -> None:
        prompts = [
            "안녕! 오늘 기분 어때?",
            "짧은 노래 가사 추천해줘.",
            "최근 핫한 인테리어 트렌드 알려줘.",
        ]
        self.client.post("/persona/chat",
                         json={"prompt": random.choice(prompts), "persona_id": "aria"},
                         name="ai.chat")

    @task(8)
    def admin_users_search(self) -> None:
        self.client.get("/api/v1/admin/users?email=&limit=10", name="admin.users")

    @task(5)
    def device_heartbeat(self) -> None:
        self.client.post("/api/v1/devices/heartbeat",
                         json={"battery": random.randint(20, 100), "firmware_version": "1.0.2"},
                         name="device.heartbeat")


@events.quitting.add_listener
def _(environment, **kw):
    stats = environment.stats
    print(f"\n=== Locust Summary ===")
    print(f"Total: {stats.total.num_requests}, Failures: {stats.total.num_failures}, "
          f"p95: {stats.total.get_response_time_percentile(0.95)}ms, "
          f"p99: {stats.total.get_response_time_percentile(0.99)}ms")
