###############################################################################
# rds-password-rotation.tf
#
# Secrets Manager 회전 hook + RDS master password 동기 Lambda.
#
# 흐름
# ----
# 1) RDS master password 가 Secrets Manager 의 iconia/${env}/db/master_password 에
#    저장되어 있음 (seed-db-password.ps1 가 1회 부트스트랩).
# 2) 본 Lambda 가 secret 의 자동 회전 trigger.
#    AWSPENDING -> RDS modify-db-instance -> testSecret -> AWSCURRENT.
# 3) 회전 완료 후 운영자는 trigger-deploy.ps1 한 번 발사하면 EC2 가
#    ec2-pull-and-restart.sh 의 inject_database_url 로 새 비밀번호를 fetch -
#    EC2 측 동기화 완료.
#
# 본 stack 은 자동 회전 schedule 를 강제하지 않는다 - aws_secretsmanager_rotation
# 의 rotation_rules.automatically_after_days 기본 30 일을 적용하되, 운영팀이
# 회전 정책을 결정한 뒤 변수로 -1 (회전 비활성) 또는 7~90 일로 조정.
###############################################################################

variable "enable_rds_password_rotation" {
  description = "RDS master password 자동 회전 활성 여부. false 면 Lambda 만 만들고 회전 스케줄은 비활성."
  type        = bool
  default     = false
}

variable "rds_password_rotation_days" {
  description = "자동 회전 주기 (일). 7~365 권장."
  type        = number
  default     = 30
}

# -----------------------------------------------------------------------------
# Lambda 패키징.
# -----------------------------------------------------------------------------
data "archive_file" "rds_password_rotator" {
  type        = "zip"
  source_file = "${path.module}/lambda/rds_password_rotator.py"
  output_path = "${path.module}/.terraform/lambda-rds-password-rotator.zip"
}

# -----------------------------------------------------------------------------
# IAM role for Lambda.
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "rds_password_rotator_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "rds_password_rotator" {
  name               = "${local.name_prefix}-rds-password-rotator-role"
  assume_role_policy = data.aws_iam_policy_document.rds_password_rotator_assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "rds_password_rotator_inline" {
  statement {
    sid = "SecretsManagerRotation"
    actions = [
      "secretsmanager:DescribeSecret",
      "secretsmanager:GetSecretValue",
      "secretsmanager:PutSecretValue",
      "secretsmanager:UpdateSecretVersionStage",
    ]
    resources = [
      "arn:aws:secretsmanager:${local.region}:${local.account_id}:secret:iconia/${var.env}/db/*",
    ]
  }

  statement {
    sid       = "GetRandomPassword"
    actions   = ["secretsmanager:GetRandomPassword"]
    resources = ["*"]
  }

  statement {
    sid = "RDSModifyMasterPassword"
    actions = [
      "rds:ModifyDBInstance",
      "rds:DescribeDBInstances",
    ]
    resources = ["*"] # rds:ModifyDBInstance 는 resource scoping 이 까다로움 - 운영팀이 condition 으로 좁힐 수 있음.
  }

  statement {
    sid = "CloudWatchLogs"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = [
      "arn:aws:logs:${local.region}:${local.account_id}:log-group:/aws/lambda/${local.name_prefix}-rds-password-rotator*",
    ]
  }
}

resource "aws_iam_role_policy" "rds_password_rotator_inline" {
  name   = "${local.name_prefix}-rds-password-rotator-inline"
  role   = aws_iam_role.rds_password_rotator.id
  policy = data.aws_iam_policy_document.rds_password_rotator_inline.json
}

# -----------------------------------------------------------------------------
# Lambda 함수.
# -----------------------------------------------------------------------------
resource "aws_lambda_function" "rds_password_rotator" {
  function_name = "${local.name_prefix}-rds-password-rotator"
  role          = aws_iam_role.rds_password_rotator.arn
  runtime       = "python3.12"
  handler       = "rds_password_rotator.lambda_handler"
  timeout       = 300
  memory_size   = 256

  filename         = data.archive_file.rds_password_rotator.output_path
  source_code_hash = data.archive_file.rds_password_rotator.output_base64sha256

  environment {
    variables = {
      RDS_INSTANCE_IDENTIFIER = (
        length(aws_db_instance.postgres) > 0
        ? aws_db_instance.postgres[0].id
        : ""
      )
      PASSWORD_LENGTH = "32"
      LOG_LEVEL       = "INFO"
    }
  }

  tags = merge(var.tags, { purpose = "rds-password-rotator" })
}

# Secrets Manager 가 Lambda 호출 가능하도록 resource policy.
resource "aws_lambda_permission" "allow_secrets_manager_invoke" {
  statement_id  = "AllowSecretsManagerInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.rds_password_rotator.function_name
  principal     = "secretsmanager.amazonaws.com"
}

# -----------------------------------------------------------------------------
# Rotation schedule - 활성 시에만 (enable_rds_password_rotation=true).
# secret 자체는 seed-db-password.ps1 가 outside-Terraform 으로 만든 자원이므로
# data source 로 조회.
# -----------------------------------------------------------------------------
data "aws_secretsmanager_secret" "db_master" {
  count = var.enable_rds_password_rotation ? 1 : 0
  name  = "iconia/${var.env}/db/master_password"
}

resource "aws_secretsmanager_secret_rotation" "db_master" {
  count               = var.enable_rds_password_rotation ? 1 : 0
  secret_id           = data.aws_secretsmanager_secret.db_master[0].id
  rotation_lambda_arn = aws_lambda_function.rds_password_rotator.arn

  rotation_rules {
    automatically_after_days = var.rds_password_rotation_days
  }

  depends_on = [aws_lambda_permission.allow_secrets_manager_invoke]
}

output "rds_password_rotator_function_name" {
  description = "RDS master password 회전 Lambda 이름. 수동 회전: aws secretsmanager rotate-secret --secret-id iconia/<env>/db/master_password"
  value       = aws_lambda_function.rds_password_rotator.function_name
}
