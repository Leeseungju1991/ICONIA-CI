###############################################################################
# terraform/multi-region/secrets-replication.tf
#
# Secrets Manager 의 multi-region replication 설정.
#
# 활성화 조건: enable_multi_region=true AND secrets_replication_enabled=true.
#
# 동작:
#   - 본 모듈은 secondary region 자체 secret 을 *생성하지 않음*.
#   - Primary 의 기존 secret 에 `replica { region = secondary }` 를 추가해야 함.
#   - 단, Terraform AWS provider 의 aws_secretsmanager_secret 의 replica block 은
#     primary secret 리소스 자체를 수정해야 작동 (cross-region 복제는 primary
#     주체로만 설정 가능).
#   - 따라서 본 파일은 *변경 안내 docs* + *secondary region 의 권한/로그*만 다루고,
#     실제 replica block 추가는 primary stack 의 secret 정의에 적용하도록 운영팀에
#     안내 (docs/multi-region.md §secrets 참조).
#
# RPO ~ 0 (Secrets Manager replica 는 동기 복제).
###############################################################################

# -----------------------------------------------------------------------------
# Secondary region 의 secrets 읽기 권한 — replica 가 생성되면 EC2/Lambda 가 동일
# 시크릿 ID 로 secondary region 에서도 GetSecretValue 가능. 본 리소스는 IAM
# policy doc 만 정의 — 실제 attach 는 primary stack 의 EC2 role 에 추가.
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "secrets_read_secondary" {
  count = local.sm_enabled

  statement {
    sid    = "ReadReplicatedSecretsInSecondary"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    # ARN 패턴: 같은 secret name 이 secondary region 에서 다른 region 부분으로 노출.
    # Replicated secret 의 ARN: arn:aws:secretsmanager:<secondary>:<acct>:secret:<name>-<random>.
    resources = [
      "arn:aws:secretsmanager:${var.secondary_region}:${local.account_id}:secret:iconia/${var.env}/*",
    ]
  }
}

resource "aws_iam_policy" "secrets_read_secondary" {
  count    = local.sm_enabled
  provider = aws.primary

  name        = "${local.name_prefix}-secrets-read-secondary"
  description = "Replicated secrets read in secondary region (${var.secondary_region})."
  policy      = data.aws_iam_policy_document.secrets_read_secondary[0].json

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# Secondary region 의 CloudWatch log group — secret rotation 감사 로그.
# (rotator Lambda 가 secondary region 에서 실행되지는 않으나, replicated secret
#  의 access audit 는 CloudTrail 통해 별도 수집.)
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "secrets_audit_secondary" {
  count    = local.sm_enabled
  provider = aws.secondary

  name              = "/iconia/${var.env}/secrets-audit-secondary"
  retention_in_days = 90

  tags = merge(local.common_tags, {
    Name    = "${local.name_prefix}-secrets-audit-secondary"
    Purpose = "secrets-manager-replication-audit"
  })
}
