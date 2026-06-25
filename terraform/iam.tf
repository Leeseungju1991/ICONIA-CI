###############################################################################
# iam.tf - EC2 instance role.
#
# 본 인프라는 EC2 한 호스트에서 Server + AI + Admin 3 서비스를 systemd 로 운영.
# 따라서 IAM 도 단일 instance profile 로 통합. (Server 와 AI 의 권한 분리는
# 향후 ECS/EKS 분할 시 별도 stack 으로.)
#
# 권한:
#   - Artifacts 버킷: GetObject + ListBucket (배포 시 pull).
#   - Events 버킷: iconia/events/* + iconia/voice/* Put/Get/Delete + List(prefix).
#   - Exports 버킷: iconia/exports/* Put/Get/Delete (presign 발급).
#   - Firmware 버킷: GetObject (OTA presign read-only).
#   - Secrets Manager: iconia/${env}/* GetSecretValue/DescribeSecret.
#   - CloudWatch metrics: namespace ICONIA/{Server,AI,Audit,Admin}.
#   - CloudWatch logs: log-group /iconia/${env}/{server,ai,admin,audit}.
#   - EFS: ClientMount + ClientWrite (access point 한정).
#   - SSM: managed-instance core (Session Manager + Run Command).
###############################################################################

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ec2" {
  name               = "${local.name_prefix}-ec2-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
  tags               = var.tags
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${local.name_prefix}-ec2-instance-profile"
  role = aws_iam_role.ec2.name
}

# SSM Session Manager + Run Command (managed instance core).
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# CloudWatch Agent (메트릭/로그 수집).
resource "aws_iam_role_policy_attachment" "cloudwatch_agent" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

data "aws_iam_policy_document" "ec2_inline" {
  # Artifacts: 배포 tarball pull.
  statement {
    sid       = "ArtifactsRead"
    actions   = ["s3:GetObject", "s3:GetObjectVersion"]
    resources = ["${aws_s3_bucket.artifacts.arn}/*"]
  }
  statement {
    sid       = "ArtifactsList"
    actions   = ["s3:ListBucket", "s3:ListBucketVersions"]
    resources = [aws_s3_bucket.artifacts.arn]
  }

  # Events 버킷: iconia/events/* + iconia/voice/* Put/Get/Delete + List(prefix).
  statement {
    sid     = "EventsBucketPutGetDelete"
    actions = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject", "s3:AbortMultipartUpload"]
    resources = [
      "${aws_s3_bucket.events.arn}/iconia/events/*",
      "${aws_s3_bucket.events.arn}/iconia/voice/*",
    ]
  }
  statement {
    sid       = "EventsBucketList"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.events.arn]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["iconia/*"]
    }
  }

  # Exports 버킷: iconia/exports/* Put/Get/Delete (presign 발급).
  statement {
    sid     = "ExportsBucketPutGetDelete"
    actions = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"]
    resources = [
      "${aws_s3_bucket.exports.arn}/iconia/exports/*",
    ]
  }

  # Firmware 버킷: GetObject 만.
  statement {
    sid       = "FirmwareReadOnly"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.firmware.arn}/firmware/*"]
  }

  # Secrets Manager: iconia/${env}/* + iconia/server/* (cross-env 공유 시크릿 경로).
  # iconia/server/* — openai-api-key 등 env-agnostic 운영 시크릿이 이 prefix 를 사용한다.
  statement {
    sid     = "SecretsManagerScope"
    actions = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [
      "arn:aws:secretsmanager:${local.region}:${local.account_id}:secret:iconia/${var.env}/*",
      "arn:aws:secretsmanager:${local.region}:${local.account_id}:secret:iconia/server/*",
    ]
  }

  # CloudWatch metric put - namespace 한정.
  statement {
    sid       = "CloudWatchMetricsPut"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = ["ICONIA/Server", "ICONIA/AI", "ICONIA/Admin", "ICONIA/Audit"]
    }
  }

  # CloudWatch logs append - log-group 한정.
  statement {
    sid     = "CloudWatchLogsAppend"
    actions = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams", "logs:CreateLogGroup"]
    resources = [
      "arn:aws:logs:${local.region}:${local.account_id}:log-group:/iconia/${var.env}/*",
    ]
  }

  # EFS access point 한정 mount.
  # 사용자 요청 8종 정합 — ClientRootAccess 제거 (POSIX uid 0 강등 회귀 방지).
  # ClientMount + ClientWrite 만 유지. access point uid/gid 가 권한 결정 (root squash 효과).
  statement {
    sid       = "EFSMountServerRoot"
    actions   = ["elasticfilesystem:ClientMount", "elasticfilesystem:ClientWrite"]
    resources = [aws_efs_file_system.persona.arn]
    condition {
      test     = "StringEquals"
      variable = "elasticfilesystem:AccessPointArn"
      values   = [aws_efs_access_point.server_root.arn]
    }
  }

  # RDS IAM database authentication - master password 와 별개로 짧은 만료 토큰으로 접속.
  statement {
    sid     = "RDSConnect"
    actions = ["rds-db:connect"]
    resources = [
      "arn:aws:rds-db:${local.region}:${local.account_id}:dbuser:*/${var.db_username}",
    ]
  }
}

resource "aws_iam_role_policy" "ec2_inline" {
  name   = "${local.name_prefix}-ec2-inline"
  role   = aws_iam_role.ec2.id
  policy = data.aws_iam_policy_document.ec2_inline.json
}
