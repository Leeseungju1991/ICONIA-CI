# 6. CI — ICONIA AWS 배포 코드

ICONIA 의 1~5번 폴더(HW / SERVER / AI / APP / ADMIN)는 **로컬 전용** 코드 저장소다.
본 폴더는 그중 **SERVER / AI / ADMIN** 3개를 AWS 단일 EC2 호스트로 배포하는 인프라
코드와 배포 스크립트를 담는다. HW(펌웨어 OTA)와 APP(Expo EAS Build)은 별도 트랙이다.

AWS 구성: **Route53 + EC2 + S3 + RDB(PostgreSQL) + EFS** (5종).

원격: <https://github.com/Leeseungju1991/ICONIA-CI> (main 브랜치만)

## 구성 한눈에

```
6. CI/
├── terraform/                     # IaC (Route53 + EC2 + S3 + EFS)
│   ├── main.tf                    # provider, backend(S3+DDB lock)
│   ├── variables.tf
│   ├── network.tf                 # VPC / Subnet / IGW / NAT / SG
│   ├── ec2.tf                     # 단일 EC2 + EIP + user-data
│   ├── s3.tf                      # events / exports / firmware / artifacts
│   ├── rds.tf                     # PostgreSQL (instance / aurora-serverless-v2 분기)
│   ├── efs.tf                     # Persona persistence (사용자별 격리)
│   ├── iam.tf                     # EC2 instance role (SSM/CW/S3/EFS)
│   ├── route53.tf                 # api/ai/admin A record -> EIP
│   ├── outputs.tf
│   └── terraform.tfvars.example
├── ec2-bootstrap/
│   └── user-data.sh.tftpl         # 최초 부팅 1회 (ec2.tf 가 templatefile)
├── deploy/
│   ├── systemd/
│   │   ├── iconia-server.service  # :8080  Server (Express)
│   │   ├── iconia-ai.service      # :8081  AI (Genome)
│   │   └── iconia-admin.service   # :3000  Admin (Next.js standalone)
│   ├── nginx/
│   │   ├── iconia.conf            # 3 server block (api/ai/admin)
│   │   └── snippets-iconia-proxy.conf
│   └── aws/                       # CloudWatch alarms.tf + IAM/KMS/S3 policy JSON (reference)
└── scripts/
    ├── build-and-upload.ps1       # 로컬(Windows) 빌드 -> S3 artifacts 업로드
    ├── trigger-deploy.ps1         # SSM RunCommand 로 EC2 pull-and-restart 호출
    └── ec2-pull-and-restart.sh    # EC2 호스트에서 실행 (user-data + SSM)
```

## 배포 모델

```
[ Local Windows ]                    [ AWS ]
  1~5번 폴더 ──build─▶  tar.gz  ──▶  S3 artifacts bucket  ──pull──▶  EC2 host
  (GitHub X)         (PowerShell)    (private, SSE)         (SSM RunCommand)
                                                                │
                                                                ├─ systemd: iconia-server  (Express :8080)
                                                                ├─ systemd: iconia-ai      (Genome  :8081)
                                                                ├─ systemd: iconia-admin   (Next.js :3000)
                                                                └─ nginx 443 (host header routing)
                                                                       │
                              ┌─ api.<root>   ─▶ :8080 (Server)        │
   Route53 hosted zone ───────┼─ ai.<root>    ─▶ :8081 (AI)            ▼
                              └─ admin.<root> ─▶ :3000 (Admin)     EFS /mnt/efs/iconia (Persona)
                                                                   S3 events/exports/firmware (직접 사용)
```

1. **1~5번 폴더는 GitHub 에 없다.** 본 폴더(6.CI)만 GitHub 와 동기화된다.
2. 로컬에서 `build-and-upload.ps1` 가 SERVER/AI/ADMIN 을 각각 빌드해 tar.gz 로 묶어 S3 `artifacts/` 에 업로드.
3. `trigger-deploy.ps1` 가 SSM RunCommand 로 EC2 의 `iconia-pull-and-restart.sh` 호출.
4. EC2 가 S3 에서 최신 tarball pull → `/opt/iconia/{server,ai,admin}` 갱신 → `systemctl restart`.

## 1회 부트스트랩 (운영자)

```powershell
# 0) AWS CLI 설정 (운영자 IAM 계정).
aws configure   # Access Key / Secret / region=ap-northeast-2

# 1) Terraform state 버킷 + DynamoDB lock 테이블 1회 수동 생성.
aws s3api create-bucket --bucket iconia-tfstate-<ACCOUNT_ID> --region ap-northeast-2 `
  --create-bucket-configuration LocationConstraint=ap-northeast-2
aws s3api put-bucket-versioning --bucket iconia-tfstate-<ACCOUNT_ID> --versioning-configuration Status=Enabled
aws s3api put-public-access-block --bucket iconia-tfstate-<ACCOUNT_ID> `
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws dynamodb create-table --table-name iconia-tfstate-lock `
  --attribute-definitions AttributeName=LockID,AttributeType=S `
  --key-schema AttributeName=LockID,KeyType=HASH `
  --billing-mode PAY_PER_REQUEST `
  --region ap-northeast-2

# 2) tfvars 작성.
cd "6. CI/terraform"
copy terraform.tfvars.example terraform.tfvars
# terraform.tfvars 의 root_domain / hosted_zone_id 등 채우기.

# 3) terraform init/plan/apply.
terraform init `
  -backend-config="bucket=iconia-tfstate-<ACCOUNT_ID>" `
  -backend-config="key=iconia/terraform.tfstate" `
  -backend-config="region=ap-northeast-2" `
  -backend-config="dynamodb_table=iconia-tfstate-lock"
terraform plan -out=tfplan
terraform apply tfplan

# 4) outputs 확인.
terraform output -raw artifacts_bucket_name
terraform output -raw ec2_instance_id
terraform output -raw ec2_public_ip
```

## 첫 배포 (apply 직후)

EC2 가 막 떴지만 artifacts 버킷이 비어있어 user-data 의 첫 pull 은 비어 있는 상태로
스킵된다. 운영자가 즉시 로컬에서 빌드 후 push 해야 서비스가 살아난다.

```powershell
cd "C:\Users\user\Music\ICONIA"

$env:ICONIA_ARTIFACTS_BUCKET = (terraform -chdir="6. CI/terraform" output -raw artifacts_bucket_name)
$env:ICONIA_EC2_INSTANCE_ID  = (terraform -chdir="6. CI/terraform" output -raw ec2_instance_id)

# 1) 전부 빌드 + 업로드 (server / ai / admin + _bootstrap).
pwsh -File "6. CI\scripts\build-and-upload.ps1" -Service all

# 2) EC2 가 pull 하도록 트리거 (SSM Run Command).
pwsh -File "6. CI\scripts\trigger-deploy.ps1" -Service all

# 3) Route53 도메인이 발급한 NS 로 매핑되어 있으면 곧 https://api.<root>/health 응답.
```

이후 운영 중 갱신은 같은 흐름 — `-Service server` 등으로 단일 서비스 부분 배포.

```powershell
pwsh -File "6. CI\scripts\build-and-upload.ps1" -Service server -TriggerDeploy
```

## 운영 메모

- **TLS**: nginx 가 `letsencrypt` 경로의 인증서를 참조한다. 첫 부팅 후 EC2 에 SSM 으로
  들어가 `certbot --nginx -d api.<root> -d ai.<root> -d admin.<root>` 발급 필요.
  발급 후 nginx 가 자동 reload.
- **시크릿**: `/etc/iconia.{server,ai,admin}.env` 는 Secrets Manager 에서 부팅 시 fetch.
  본 폴더에 평문으로 절대 커밋하지 말 것 (`.gitignore` 가 `.env*` 차단).
- **CloudWatch**: alarms.tf (`deploy/aws/alarms.tf`) 는 별도 stack 으로 분리되어 있다.
  terraform/ 디렉터리와 별개로 apply 가 필요하면 그 디렉터리에서 init 한다 (참고용 reference 자산).
- **HW 펌웨어 OTA**: firmware S3 버킷에 운영자가 별도 PowerShell 로 업로드.
  EC2 의 Server 가 presign URL 만 발급 (read-only). 본 폴더는 OTA 절차를 직접 자동화하지 않음.
- **APP (Expo)**: EAS Build 가 빌드. App Store / Play 배포 별도. 본 폴더는 무관.

## 무엇이 들어 있지 않은가

- **GitHub Actions / CodePipeline / CodeBuild**: 본 폴더에는 아직 미설치. 1~5 가 각자 별도 GitHub
  repo 에 있으므로 향후 클라우드 CI 도입 시 본 폴더의 Terraform 과 `scripts/build-and-upload.ps1`
  대신 GitHub Actions 가 빌드/업로드를 수행하도록 전환 가능.
- **ALB / ASG**: 단일 EC2 + nginx 호스트 헤더 라우팅으로 충분. 확장 필요 시 ALB + Target Group 추가.
