###############################################################################
# github-oidc.tf — GitHub Actions OIDC 신뢰 + 배포 IAM 역할.
#
# 2026-06-05 — 신규. deploy.yml 의 aws-actions/configure-aws-credentials@v4
# (role-to-assume = AWS_DEPLOY_ROLE_ARN) 가 가정할 역할을 정본 정의.
#
# 역할이 가진 권한:
#   - S3 artifacts 버킷: PutObject / GetObject / ListBucket (빌드 산출물 업로드).
#   - SSM SendCommand: 본 stack 의 EC2 ASG 인스턴스에 AWS-RunShellScript 트리거.
#   - EC2/ASG describe: 인스턴스 ID 동적 조회 (deploy.yml 의 instance-id 미지정 시).
#
# 신뢰 정책:
#   GitHub Actions 의 OIDC token 발급자(token.actions.githubusercontent.com)에서
#   var.github_org/var.github_repo_ci 로 발급된 JWT 만 허용. branch/ref 는
#   workflow_dispatch 에서 main 외 ref 도 운영 가능하도록 와일드카드로 둔다 —
#   branch 제한이 필요하면 var.github_oidc_subject_pattern 으로 제한 가능.
###############################################################################

# 1) GitHub Actions OIDC provider — 계정 전역 1개. 이미 생성돼 있으면 import.
#    AWS 1개 계정에 1개만 둘 수 있어, terraform 이 멱등 관리.
resource "aws_iam_openid_connect_provider" "github" {
  count          = var.create_github_oidc_provider ? 1 : 0
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  # GitHub Actions OIDC 인증서 thumbprint. AWS 가 권장하는 표준 값.
  # 참고: https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/configuring-openid-connect-in-amazon-web-services
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
  tags            = var.tags
}

locals {
  github_oidc_provider_arn = (
    var.create_github_oidc_provider
    ? aws_iam_openid_connect_provider.github[0].arn
    : "arn:aws:iam::${local.account_id}:oidc-provider/token.actions.githubusercontent.com"
  )
  # 기본값: main 브랜치 전용 (workflow_dispatch 도 main 에서만 가능).
  # 모든 ref 허용이 필요하면 github_oidc_subject_pattern = "repo:<org>/<repo>:*" 로 override.
  github_oidc_subject = (
    var.github_oidc_subject_pattern != ""
    ? var.github_oidc_subject_pattern
    : "repo:${var.github_org}/${var.github_repo_ci}:ref:refs/heads/main"
  )
}

# 2) 배포 역할의 신뢰 정책 — GitHub OIDC JWT 의 sub claim 매칭만 허용.
data "aws_iam_policy_document" "github_deploy_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.github_oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [local.github_oidc_subject]
    }
  }
}

# 3) 배포 역할.
resource "aws_iam_role" "github_deploy" {
  name               = "${local.name_prefix}-github-deploy"
  assume_role_policy = data.aws_iam_policy_document.github_deploy_assume.json
  # IAM API rejects non-Latin1 characters in description, so keep this ASCII.
  description          = "GitHub Actions (ICONIA-CI deploy.yml) OIDC role: S3 artifacts RW + SSM SendCommand + EC2 describe."
  max_session_duration = 3600
  tags                 = var.tags
}

# 4) S3 artifacts 버킷 권한 — build 잡이 산출물 업로드.
data "aws_iam_policy_document" "github_deploy_s3" {
  statement {
    sid    = "ArtifactsBucketRW"
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:PutObjectAcl",
      "s3:PutObjectTagging",
      "s3:GetObject",
      "s3:GetObjectTagging",
      "s3:GetObjectVersion",
      "s3:DeleteObject",
      "s3:AbortMultipartUpload",
      "s3:ListBucketMultipartUploads",
    ]
    resources = ["${aws_s3_bucket.artifacts.arn}/*"]
  }
  statement {
    sid       = "ArtifactsBucketList"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.artifacts.arn]
  }
}

resource "aws_iam_policy" "github_deploy_s3" {
  name        = "${local.name_prefix}-github-deploy-s3"
  description = "GitHub Actions deploy 역할 — artifacts 버킷 R/W."
  policy      = data.aws_iam_policy_document.github_deploy_s3.json
}

resource "aws_iam_role_policy_attachment" "github_deploy_s3" {
  role       = aws_iam_role.github_deploy.name
  policy_arn = aws_iam_policy.github_deploy_s3.arn
}

# 5) SSM 권한 — deploy.yml step 4 가 AWS-RunShellScript 로 EC2 pull-and-restart 트리거.
data "aws_iam_policy_document" "github_deploy_ssm" {
  # SendCommand 는 instance + document 두 resource ARN 을 동시에 지정해야 작동.
  # EC2 ARN 을 tag 필터로 좁히고, document 는 AWS-RunShellScript 단독으로 제한.
  statement {
    sid    = "SsmSendCommandToInstancesByTag"
    effect = "Allow"
    actions = [
      "ssm:SendCommand",
    ]
    resources = [
      "arn:aws:ec2:${local.region}:${local.account_id}:instance/*",
    ]
    condition {
      test     = "StringLike"
      variable = "ssm:resourceTag/service"
      values   = ["iconia"]
    }
  }
  statement {
    sid    = "SsmSendCommandDocumentScope"
    effect = "Allow"
    actions = [
      "ssm:SendCommand",
    ]
    resources = [
      "arn:aws:ssm:${local.region}::document/AWS-RunShellScript",
    ]
  }
  statement {
    sid    = "SsmCommandInvocationRead"
    effect = "Allow"
    actions = [
      "ssm:GetCommandInvocation",
      "ssm:ListCommandInvocations",
      "ssm:DescribeInstanceInformation",
    ]
    resources = ["*"] # describe/get 는 resource-level ARN 제약 불가 (AWS 설계).
  }
  statement {
    sid    = "Ec2DescribeForInstanceLookup"
    effect = "Allow"
    actions = [
      "ec2:DescribeInstances",
      "ec2:DescribeTags",
      "autoscaling:DescribeAutoScalingGroups",
      "autoscaling:DescribeAutoScalingInstances",
    ]
    resources = ["*"] # describe-* 는 본질적으로 wildcard 만 허용.
  }
}

resource "aws_iam_policy" "github_deploy_ssm" {
  name        = "${local.name_prefix}-github-deploy-ssm"
  description = "GitHub Actions deploy 역할 — SSM SendCommand + EC2 describe."
  policy      = data.aws_iam_policy_document.github_deploy_ssm.json
}

resource "aws_iam_role_policy_attachment" "github_deploy_ssm" {
  role       = aws_iam_role.github_deploy.name
  policy_arn = aws_iam_policy.github_deploy_ssm.arn
}

# 6) ECR 권한 — deploy.yml 이 amazon-ecr-login 액션 + docker push 로 이미지 업로드.
#    최소 권한: GetAuthorizationToken (계정 전역), 나머지는 ECR repo 범위로 제한.
#    2026-06-24 추가 — 신규 계정 169063643478 마이그레이션 시 누락된 권한.
data "aws_iam_policy_document" "github_deploy_ecr" {
  statement {
    sid    = "EcrGetAuthToken"
    effect = "Allow"
    actions = [
      "ecr:GetAuthorizationToken",
    ]
    resources = ["*"] # GetAuthorizationToken 은 resource-level 제약 불가 (AWS 제한).
  }
  statement {
    sid    = "EcrRepoPushPull"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:PutImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeRepositories",
      "ecr:ListImages",
    ]
    resources = ["arn:aws:ecr:${local.region}:${local.account_id}:repository/iconia*"]
  }
  statement {
    sid    = "EcsDeployControl"
    effect = "Allow"
    actions = [
      "ecs:UpdateService",
      "ecs:DescribeServices",
      "ecs:DescribeClusters",
      "ecs:RegisterTaskDefinition",
      "ecs:DescribeTaskDefinition",
      "ecs:ListTaskDefinitions",
    ]
    resources = ["*"] # ecs:UpdateService 는 cluster/service ARN 으로 좁힐 수 있으나
    # ECS 미구성 단계에서 ARN 미확정 — 인프라 확정 후 좁힐 것.
  }
}

resource "aws_iam_policy" "github_deploy_ecr" {
  name        = "${local.name_prefix}-github-deploy-ecr"
  description = "GitHub Actions deploy 역할 — ECR push/pull + ECS service update (신규 계정 마이그레이션)."
  policy      = data.aws_iam_policy_document.github_deploy_ecr.json
}

resource "aws_iam_role_policy_attachment" "github_deploy_ecr" {
  role       = aws_iam_role.github_deploy.name
  policy_arn = aws_iam_policy.github_deploy_ecr.arn
}

###############################################################################
# 변수 + 출력.
###############################################################################

variable "create_github_oidc_provider" {
  description = "GitHub Actions OIDC provider 를 본 stack 이 직접 생성할지. 이미 다른 stack/계정에 만들어져 있으면 false."
  type        = bool
  default     = true
}

variable "github_org" {
  description = "GitHub organization 또는 user 명 (예: Leeseungju1991)."
  type        = string
  default     = "Leeseungju1991"
}

variable "github_repo_ci" {
  description = "deploy.yml 워크플로가 위치한 CI 레포 이름 (예: ICONIA-CI)."
  type        = string
  default     = "ICONIA-CI"
}

variable "github_oidc_subject_pattern" {
  description = "OIDC sub claim 매칭 패턴. 빈 값이면 repo:<org>/<repo_ci>:ref:refs/heads/main (main 브랜치 전용). 모든 ref 허용이 필요하면 'repo:<org>/<repo_ci>:*' 로 명시."
  type        = string
  default     = ""
}

output "github_deploy_role_arn" {
  description = "deploy.yml 의 AWS_DEPLOY_ROLE_ARN secret 에 등록할 역할 ARN."
  value       = aws_iam_role.github_deploy.arn
}
