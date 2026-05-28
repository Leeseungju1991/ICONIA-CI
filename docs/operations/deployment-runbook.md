# Deployment Runbook

## 1. 배포 대상

| Service | 빌드 산출물 | 배포 방식 | 헬스 |
|---|---|---|---|
| SERVER | tar.gz (Node + Prisma) | S3 → EC2 systemd | `/health` :8080 |
| AI | tar.gz (Node) | S3 → EC2 systemd | `/health` :8081 |
| ADMIN | Next.js standalone tar.gz | S3 → EC2 systemd | `/` :3000 (ALB :8082) |
| HW (Firmware) | bin + signature | S3 → OTA delivery | post-OTA health |

## 2. 표준 배포 절차

### 2.1 로컬 빌드 + S3 업로드

```powershell
$env:ICONIA_ARTIFACTS_BUCKET = "iconia-prod-artifacts-<account>"
$env:ICONIA_EC2_INSTANCE_ID = "i-<id>"

pwsh -File "6. CI/scripts/build-and-upload.ps1" -Service <server|ai|admin>
```

특이사항:
- **ADMIN**: 빌드 전 `.next` 디렉토리 삭제 (Next.js stale cache 회피)
- **SERVER**: `npx prisma generate` 자동 포함
- **AI**: 의존성 변경 시 `npm ci` 결과 검증

### 2.2 EC2 트리거 (SSM Run Command)

```powershell
pwsh -File "6. CI/scripts/trigger-deploy.ps1" -Service <server|ai|admin>
```

내부 동작:
1. S3 의 `latest.tar.gz` 를 EC2 가 download
2. `/opt/iconia/<svc>.old.<TS>` 로 백업 → 새 install
3. 의존성 (`npm ci --omit=dev`)
4. SERVER 만 `prisma migrate deploy` (no pending 인 경우 skip)
5. systemd restart
6. health check (port + retry)
7. 성공 시 완료 / 실패 시 rollback (admin.old.<TS> 복원)

### 2.3 검증

```bash
curl -s -o /dev/null -w "%{http_code}\n" http://<alb>:80/health        # SERVER
curl -s -o /dev/null -w "%{http_code}\n" http://<alb>:8082/login       # ADMIN
```

## 3. Rollback

- ec2-pull-and-restart.sh 가 자동 rollback (health 실패 시)
- 수동 rollback: `/opt/iconia/<svc>.old.<TS>` 디렉토리 swap + systemd restart

## 4. 알려진 이슈

| Issue | Workaround |
|---|---|
| trigger-deploy healthcheck retry 부족 (재시동 늦으면 false-negative) | 재 trigger / chunk 직접 검증 |
| ADMIN `.next/cache` stale | 빌드 전 `rm -rf .next` 강제 |
| AWS CLI 출력 인코딩 (Windows cp949) | `chcp 65001` + PowerShell 의 UTF8 encoding |
| Push 거부 시 (auth/permission) | `gh auth status` + 권한 확인 |

## 5. 단계 별 배포 (canary / blue-green)

현재: rolling (한 instance) — staging/prod 분리는 Stage 4 의 향후 작업.

Stage 7 production-ready 시:
- **canary**: ALB target group 의 10% 가중치 → 50% → 100%
- **blue-green**: 신규 target group + ALB switch
- 자동 rollback: health/error rate 임계 초과 시
