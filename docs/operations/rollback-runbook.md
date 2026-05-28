# Rollback Runbook

## 1. Trigger

다음 조건 중 하나라도 발생 시 rollback 검토:

- 배포 후 5분 내 error rate > 5%
- 배포 후 health check 실패 (5회 연속)
- 사용자 critical bug 보고 (P0)
- 보안 사고 감지

## 2. Service Rollback

### 2.1 자동 rollback (ec2-pull-and-restart.sh)

배포 스크립트가 health check 실패 시 자동 수행:
1. `mv /opt/iconia/<svc> /opt/iconia/<svc>.failed.<TS>`
2. `mv /opt/iconia/<svc>.old.<TS_prev> /opt/iconia/<svc>`
3. systemd restart
4. health check 통과 확인

### 2.2 수동 rollback (필요 시)

```bash
# SSM Run Command
ls -lat /opt/iconia/<svc>.old.*       # 사용 가능한 백업 확인
sudo mv /opt/iconia/<svc> /opt/iconia/<svc>.failed.manual.<TS>
sudo mv /opt/iconia/<svc>.old.<TARGET_TS> /opt/iconia/<svc>
sudo systemctl restart iconia-<svc>
curl http://127.0.0.1:<port>/health
```

## 3. Database Migration Rollback

### 3.1 Forward migration 검증
- `npx prisma migrate status` → no pending
- `prisma/migrations/<ts>_<name>/migration.sql` 의 SQL 검토

### 3.2 Rollback 가능한 경우
- 단순 column 추가 → 신 migration 으로 drop column 처리
- 단순 index/constraint 추가 → 신 migration 으로 drop

### 3.3 Rollback 어려운 경우 (DATA LOSS 위험)
- column drop → 데이터 복구 불가
- type 변경 → 데이터 변환 필요
- 이런 경우 **migrate 전 RDS snapshot 필수** + 별도 계획 수립

### 3.4 RDS 복구
```bash
aws rds describe-db-snapshots --db-instance-identifier iconia-prod-db
aws rds restore-db-instance-from-db-snapshot \
  --db-instance-identifier iconia-prod-db-restored \
  --db-snapshot-identifier <snapshot-id>
```

## 4. OTA (HW) Rollback

펌웨어는 anti-rollback 정책상 임의 downgrade 불가 (commit 7d47ae0):
- secure version 이 이전 버전보다 낮으면 펌웨어 거부
- 정식 rollback 필요 시 → 신 펌웨어로 secure version 동일/상위 + 기능적으로 이전 동작 복원

## 5. Decision Matrix

| 영향 | 사용자 수 | Action |
|---|---|---|
| Critical (서비스 다운) | All | 즉시 rollback |
| High (한 기능 다운) | All | 1시간 내 hotfix or rollback |
| Medium | Some | 4시간 내 결정 |
| Low | Few | 다음 배포에서 fix |

## 6. Post-Rollback

- [ ] 사용자 통지 (해당 시)
- [ ] postmortem 작성
- [ ] 원인 분석 + 재발 방지
- [ ] 테스트 보강
- [ ] Stage 6 wide stress 에 케이스 추가
