# Backup / Restore Runbook

## 1. Backup 정책

| 데이터 | 방식 | 빈도 | 보관 |
|---|---|---|---|
| RDS (PostgreSQL) | AWS RDS automated backup | 매일 | 7일 |
| RDS (manual snapshot) | aws CLI / Terraform | 주 1회 | 4주 |
| S3 (assets/firmware) | S3 versioning | 항시 | 영구 (life-cycle policy 적용) |
| EFS (AI persona data) | AWS Backup | 매일 | 7일 |
| Configuration (env) | AWS Secrets Manager (HD-09) | 변경 시 | 영구 (version history) |
| Audit logs | RDS table + S3 export | 매주 | 5년 |

## 2. Backup 확인

`2. SERVER/scripts/backup-verify.js` 가 매주 실행:
- 최근 backup 의 무결성 검증 (random sample row 비교)
- backup 실패 알람 → CloudWatch alarm → secops

## 3. Restore 시나리오

### 3.1 RDS 전체 복구 (사고 대응)

```bash
# 1. 사용 가능 snapshot 확인
aws rds describe-db-snapshots --db-instance-identifier iconia-prod-db

# 2. 신규 인스턴스로 복구 (기존 인스턴스 영향 없음)
aws rds restore-db-instance-from-db-snapshot \
  --db-instance-identifier iconia-prod-db-restored \
  --db-snapshot-identifier <snapshot-id> \
  --db-instance-class db.t4g.medium \
  --vpc-security-group-ids <sg>

# 3. 검증 (별도 임시 DB 로 연결)
# 4. 검증 OK 시 → 운영 DB endpoint 전환 (HD-07 승인)
```

### 3.2 특정 테이블 복구 (운영자 실수)

1. 복구된 임시 인스턴스 생성 (위 3.1 절차)
2. 특정 테이블 row export → SQL dump
3. 운영 DB 에 적용 (운영자 승인 필수)

### 3.3 사용자 한 명 복구 요청

1. audit_logs 에서 삭제 시점 확인
2. 해당 시점의 snapshot 에서 사용자 데이터 추출
3. 사용자 확인 후 복구 (선택적 — 보존 의무 데이터만)

## 4. Restore 검증

- DB 연결 + simple query
- 행 카운트 비교 (snapshot vs restored)
- application 연결 시 smoke test

## 5. 사후 조치

- backup-verify 의 다음 실행 시 새 인스턴스 포함
- audit_logs 에 restore 작업 기록
- 사용자 통지 (영향 있는 경우)

## 6. Disaster Recovery 시나리오

| 시나리오 | RTO | RPO | 대응 |
|---|---|---|---|
| 단일 EC2 장애 | 5분 | 0 | ASG 자동 재시작 |
| RDS 장애 | 30분 | 5분 (RDS multi-AZ 가정) | failover or restore from snapshot |
| Region 전체 장애 | 4시간 (HD-06) | 24시간 | Multi-region replication (Stage 4 의 향후) |
| 운영자 실수 데이터 삭제 | 1시간 | 24시간 | snapshot restore |
| Ransomware | 4시간 | 24시간 | snapshot restore + 보안 강화 |

## 7. Test (Stage 6)

- 분기 1회 disaster recovery drill (HD-12)
- backup-verify 자동 실행 결과 review
