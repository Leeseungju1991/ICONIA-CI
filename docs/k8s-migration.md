# ICONIA — V1.x Kubernetes 전환 가이드 (단계적 적용)

> 본 문서는 **V1.x 라운드의 골격**이다. **V1.0 운영은 EC2 + systemd 모델을 유지**한다 (`deploy/RUNBOOK.md`).
> K8s 전환은 fleet 1만대 이상 또는 multi-tenancy 요구가 명확해진 시점에 단계적으로 진행한다.
> 본 문서는 그 시점이 도래했을 때 운영팀이 따라갈 절차 정본이다.

---

## 0. 사전 결정 사항 (운영팀)

전환 착수 전 다음 항목이 의사결정 완료되어 있어야 한다.

| 항목 | 결정 사항 | 비고 |
|---|---|---|
| 전환 사유 | fleet 1만대 / multi-tenancy / 노이지 네이버 격리 / 멀티 리전 active-active | RUNBOOK §0 의사결정 매트릭스 |
| 리전 | ap-northeast-2 (서울) — 기존 VPC 재사용 | Multi-region 은 V2.x |
| EKS 버전 | 최신 - 1 (예: 1.31 시점에 1.30) | EKS Auto Mode 검토 |
| 노드 그룹 | 일반: m7g.large (arm64) / GPU: g5.xlarge (옵션) | Karpenter 또는 Managed NodeGroup |
| Networking CNI | AWS VPC CNI + ENABLE_POLICY=true (또는 Calico) | NetworkPolicy 지원 필수 |
| Ingress | AWS Load Balancer Controller (ALB Ingress) | 기존 ALB 운영 자산 재사용 |
| Secret 동기화 | External Secrets Operator + IRSA | 기존 Secrets Manager (`iconia/<env>/*`) 재사용 |
| 컨테이너 이미지 저장소 | ECR (`__ACCOUNT__.dkr.ecr.ap-northeast-2.amazonaws.com/iconia-{server,ai,admin}`) | 기존 S3 artifacts 와 병행 운영 |
| 관찰성 | CloudWatch Container Insights + 기존 CW log group 통합 | Prometheus 도입은 V1.x+1 |
| 데이터 | RDS / ElastiCache / EFS / S3 **변경 없음** — Pod 가 기존 리소스를 그대로 사용 | DB schema 변경 0 |

---

## 1. 전환 원칙

1. **기존 EC2 운영은 끝까지 유지** — K8s 가 1개 서비스라도 unstable 하면 즉시 ALB target 을 EC2 로 복귀.
2. **Stateless workload 만 K8s** — RDS / ElastiCache / EFS / S3 는 K8s 밖. StatefulSet 사용 0.
3. **카나리는 ALB weighted target group** — `iconia-server-eks-tg` (10%) + `iconia-server-ec2-tg` (90%) 시작.
4. **DB schema 변경 0** — K8s pod 가 기존 prisma 마이그레이션 상태 그대로 사용.
5. **회귀 0** — 각 단계에서 외부 스모크(`scripts/post-deploy-smoke.sh`) 와 `dr-restore-dryrun.yml` 통과.

---

## 2. 단계적 적용 절차

### Phase 0 — EKS 클러스터 부트스트랩 (1~2 일)

1. `terraform/` 에 `eks.tf` (별도 라운드) 추가 — 기존 VPC / Subnet 재사용
   - 노드그룹: 일반 m7g.large × 2 (Multi-AZ)
   - IRSA: `iconia-eso-sa` (Secrets Manager read), `iconia-alb-controller-sa`, `iconia-server-sa` (S3/RDS connect)
2. `kubectl get nodes` — Ready × 2 확인
3. AWS Load Balancer Controller Helm install
4. External Secrets Operator Helm install
5. Metrics Server install (HPA 동작 전제)
6. `kubectl apply -k k8s/overlays/stage --dry-run=server` — manifest validation
   - PodSecurity admission (`restricted`) 통과 확인 — `runAsNonRoot`, `readOnlyRootFilesystem`, `drop ALL` 모두 필수

**완료 조건**: `kubectl get all -n iconia-stage` 출력 (빈 namespace) + Helm chart 3종 healthy.

---

### Phase 1 — Stage 환경 1개 서비스 카나리 (3~5 일)

대상: **ADMIN** (트래픽 최소, blast radius 작음).

1. ECR 에 `iconia-admin:stage-<sha>` push (별도 CI 잡 추가)
2. `k8s/overlays/stage/kustomization.yaml` 의 `images.newTag` 를 실 tag 로 교체
3. `kubectl apply -k k8s/overlays/stage`
4. `kubectl rollout status deploy/iconia-admin -n iconia-stage` — 2 pod Ready
5. Ingress ALB 의 DNS 를 stage Route53 record (`admin.stage.<domain>`) 로 연결
6. 외부 스모크: `curl https://admin.stage.<domain>/health/ready` 200
7. 24 시간 관찰: CloudWatch error rate / Sentry / p95 latency 평소 ±10% 이내

**롤백 트리거**: 5xx > 1% 또는 p95 > 기존 EC2 stage 의 2 배 → `kubectl delete -k k8s/overlays/stage` + Route53 record 를 기존 EC2 stage 로 복귀.

---

### Phase 2 — Stage 전 서비스 + Production 카나리 진입 (1~2 주)

1. **Stage SERVER + AI 도 K8s 로 이전** — Phase 1 과 동일 절차
2. **Stage e2e** — `cross-repo-e2e.yml` 의 base URL 을 stage K8s 로 교체하여 1주일 정상
3. **Production 카나리 — SERVER 만 10%**:
   - ALB target group 2 개: `iconia-server-ec2-tg` (weight 90), `iconia-server-eks-tg` (weight 10)
   - K8s 의 Ingress 는 별도 ALB 가 아니라 **기존 ALB 의 IP-target-group 에 pod IP 등록** (AWS LB Controller `TargetGroupBinding` CRD)
   - 24 시간 관찰 → 30% → 50% → 100% (단계마다 24 시간)
4. **자동 롤백 조건**:
   - Synthetics `SuccessPercent < 95%` 5 분간
   - 5xx rate > 0.5% 5 분간
   - Gemini cost / error 알람 trip
   - → ALB weight 즉시 100% EC2 복귀, `kubectl scale deploy/iconia-server -n iconia-prod --replicas=0`

**완료 조건**: SERVER 100% K8s 트래픽으로 1주일 정상 + cost regression 0.

---

### Phase 3 — Production AI / ADMIN 이전 (1~2 주)

1. SERVER 와 동일 weighted TG 패턴으로 AI / ADMIN 순차 이전
2. AI 는 Gemini cost 알람을 특히 주시 (요청 라우팅 변경 → 호출 패턴 변화 가능)
3. ADMIN 은 Next.js cache 가 emptyDir 이므로 첫 요청 latency spike 가능 — readiness probe 가 가려줌

---

### Phase 4 — EC2 fleet 축소 + 정리 (1 주)

1. ALB 의 EC2 target group weight 0 → 1 주 더 idle 유지 (즉시 복귀 옵션)
2. `terraform/asg.tf` 의 `asg_desired_capacity=0` 설정 → EC2 instance 종료 (단, AMI / launch template 은 유지 — 즉시 복원 가능)
3. EC2 관련 CloudWatch dashboard / 알람을 K8s 동등물로 마이그레이션
4. `dr-restore-dryrun.yml` 의 검증 대상에 K8s 추가
5. `docs/k8s-migration.md` 의 본 절차 후기 작성 + `README.md` §4 항목 갱신

**완료 조건**: 1 개월 운영 0 회귀 → EC2 launch template / ASG 도 destroy.

---

## 3. 운영 점검 체크리스트 (Pre-Apply)

각 phase 진입 전 다음을 확인.

- [ ] `kubectl apply --dry-run=server -k k8s/overlays/<env>` 성공
- [ ] PodSecurity `restricted` admission 통과
- [ ] NetworkPolicy CNI 지원 활성화 (VPC CNI `ENABLE_POLICY=true`)
- [ ] IRSA role 3 종 (eso / alb / server) 매핑 완료
- [ ] ECR image push 권한 (CI OIDC role)
- [ ] Secrets Manager path `iconia/<env>/{server,ai,admin}` 존재 + JSON key 일치
- [ ] HPA 동작 전제: metrics-server Healthy
- [ ] PDB minAvailable 가 replicas 보다 작음 (deadlock 회피)
- [ ] Ingress ACM cert ARN / 호스트네임 placeholder 치환 완료
- [ ] `placeholder` image tag 미잔존 (`grep -r placeholder k8s/overlays/<env>` 결과 0)

---

## 4. 롤백 절차 (즉시 EC2 복귀)

1. ALB target group weight: EC2=100, EKS=0
2. `kubectl scale deploy/iconia-{server,ai,admin} -n iconia-prod --replicas=0` (cost 0)
3. Route53 record 변경 없음 (ALB DNS 동일)
4. Sentry / Synthetics / CloudWatch 알람 정상화 확인 (5 분 이내)
5. Post-mortem 작성 → `deploy/RUNBOOK.md` §11 incident log

**RTO 목표**: 5 분. 본 절차는 V1.x 라운드 chaos drill 의 시나리오 1 로 포함.

---

## 5. 보안 베이스라인 (manifest 가 강제하는 사항)

본 scaffold 의 base manifest 는 다음 보안 정책을 강제한다 — overlay 가 약화 불가:

- `runAsNonRoot: true` + 컴포넌트별 UID/GID 분리 (server=10001, ai=10002, admin=10003)
- `readOnlyRootFilesystem: true` — 쓰기 가능 경로는 emptyDir 로 명시
- `allowPrivilegeEscalation: false`
- `capabilities.drop: [ALL]`
- `seccompProfile: RuntimeDefault`
- `automountServiceAccountToken: false` (default — service account 사용은 IRSA 한정)
- Namespace `pod-security.kubernetes.io/enforce: restricted`
- 모든 컨테이너 resources.requests + limits 명시 (스케줄러 예측성 + cgroup 격리)
- NetworkPolicy default-deny + east-west 명시적 allow

V1.x 라운드에 Kyverno / Gatekeeper 도입 시 본 베이스라인을 ClusterPolicy 로 승격 예정.

---

## 6. 미해결 / 후속 라운드

- **Pod Identity (IRSA 후속) 마이그레이션** — EKS Pod Identity Add-on 채택 시기
- **Karpenter** — Managed NodeGroup → Karpenter 로 노드 spin-up cost 절감
- **GitOps (ArgoCD / Flux)** — 현재 scaffold 는 kubectl apply 기준. GitOps 는 V1.x+1
- **Service Mesh** — mTLS 동서 트래픽 강제는 V2.x 멀티 클러스터 단계
- **Multi-cluster / Multi-region** — Route53 health-based routing + EKS Anywhere 검토
- **GPU 추론 노드 풀** — `ai-deployment.yaml` 의 주석 처리된 nodeSelector 활성화 라운드
- **Prometheus + Grafana** — CloudWatch Container Insights 만으로는 SLO 보드 한계
- **Pact / OpenAPI contract test broker** — README §4.2 동일 항목과 정합
