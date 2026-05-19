###############################################################################
# efs-user-access-points.tf
#
# 사용자별 EFS access point 동적 프로비저너.
#
# 배경
# ----
# efs.tf 의 단일 access point (server_root) 는 /iconia 루트만 노출하므로
# 사용자 간 격리를 보장하지 못한다. 페르소나 명세는 "사용자별 SOUL 격리가 절대
# 제약" - 본 stack 은 회원가입/탈퇴 시점마다 사용자별 access point 를 만들고
# POSIX uid/gid 로 커널 단위 격리를 강제한다.
#
# 운영 모드
# --------
# 1) Server 가 회원가입 직후 SNS topic `iconia-${env}-user-events` 로
#      {"event":"user.created","user_id":"<uuid>"}
#    publish (publish 권한은 ec2 instance role 에 별도 추가 필요. iam.tf 갱신).
# 2) Lambda `iconia-${env}-efs-userspace-provisioner` 가 받아서 AP 생성.
# 3) AI 컨테이너가 사용자 응대 진입 시 해당 user_id 의 AP id 를 조회 (서버 API),
#    그 AP id 로 EFS mount (또는 NFS client side mount 옵션) - persona-ai 측 구현.
# 4) 보정용 EventBridge 스케줄: 매시간 reconcile (드물게 SNS 가 유실되어도
#    catch-up. Server 가 user 목록을 reconcile 페이로드로 publish).
#
# 본 stack 의 적정 단위
# --------------------
# - SNS, Lambda, IAM, EventBridge 까지만. 사용자별 AP 자체는 Lambda 가 동적 생성
#   (Terraform resource 로 만들 수 없는 양 - 사용자 1만명 = 1만 resource).
# - 따라서 사용자별 AP 는 Terraform state 에 추적되지 않는다. AP lifecycle 은
#   Lambda 가 일임. 운영자 콘솔에서 직접 삭제 시 다음 reconcile 때 복원.
###############################################################################

# -----------------------------------------------------------------------------
# 1. SNS topic - Server 회원가입/탈퇴 이벤트 입력 channel.
# -----------------------------------------------------------------------------
resource "aws_sns_topic" "user_events" {
  name              = "${local.name_prefix}-user-events"
  display_name      = "ICONIA user lifecycle events"
  kms_master_key_id = "alias/aws/sns"

  tags = merge(var.tags, { purpose = "user-events" })
}

# -----------------------------------------------------------------------------
# 2. Lambda 패키징 - 단일 .py 파일을 inline zip 으로 묶는다.
#    의존성은 boto3 만 사용 (AWS Lambda 런타임 내장) - layer 불필요.
# -----------------------------------------------------------------------------
data "archive_file" "efs_userspace_provisioner" {
  type        = "zip"
  source_file = "${path.module}/lambda/efs_userspace_provisioner.py"
  output_path = "${path.module}/.terraform/lambda-efs-userspace-provisioner.zip"
}

# -----------------------------------------------------------------------------
# 3. IAM role - Lambda 가 EFS AP CRUD + CloudWatch logs.
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "efs_userspace_lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "efs_userspace_lambda" {
  name               = "${local.name_prefix}-efs-userspace-provisioner-role"
  assume_role_policy = data.aws_iam_policy_document.efs_userspace_lambda_assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "efs_userspace_lambda_inline" {
  # EFS access point CRUD - 본 파일 system 한정.
  statement {
    sid = "EFSAccessPointCRUD"
    actions = [
      "elasticfilesystem:CreateAccessPoint",
      "elasticfilesystem:DescribeAccessPoints",
      "elasticfilesystem:DeleteAccessPoint",
      "elasticfilesystem:TagResource",
      "elasticfilesystem:UntagResource",
      "elasticfilesystem:ListTagsForResource",
    ]
    resources = [
      aws_efs_file_system.persona.arn,
      # access point ARN 은 동적 생성이라 wildcard. 단, CreateAccessPoint 의
      # condition 으로 file system 한정 (AWS API 자체가 FileSystemId 인자 강제).
      "arn:aws:elasticfilesystem:${local.region}:${local.account_id}:access-point/*",
    ]
  }

  # CloudWatch logs.
  statement {
    sid = "CloudWatchLogsForLambda"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = [
      "arn:aws:logs:${local.region}:${local.account_id}:log-group:/aws/lambda/${local.name_prefix}-efs-userspace-provisioner*",
    ]
  }
}

resource "aws_iam_role_policy" "efs_userspace_lambda_inline" {
  name   = "${local.name_prefix}-efs-userspace-provisioner-inline"
  role   = aws_iam_role.efs_userspace_lambda.id
  policy = data.aws_iam_policy_document.efs_userspace_lambda_inline.json
}

# -----------------------------------------------------------------------------
# 4. Lambda 함수.
# -----------------------------------------------------------------------------
resource "aws_lambda_function" "efs_userspace_provisioner" {
  function_name = "${local.name_prefix}-efs-userspace-provisioner"
  role          = aws_iam_role.efs_userspace_lambda.arn
  runtime       = "python3.12"
  handler       = "efs_userspace_provisioner.lambda_handler"
  timeout       = 60
  memory_size   = 256

  filename         = data.archive_file.efs_userspace_provisioner.output_path
  source_code_hash = data.archive_file.efs_userspace_provisioner.output_base64sha256

  environment {
    variables = {
      EFS_FILE_SYSTEM_ID = aws_efs_file_system.persona.id
      ICONIA_ENV         = var.env
      USER_ID_BASE       = "1000"
      USER_ID_SPACE      = "1000000"
      LOG_LEVEL          = "INFO"
    }
  }

  tags = merge(var.tags, { purpose = "efs-userspace-provisioner" })
}

# -----------------------------------------------------------------------------
# 5. SNS -> Lambda subscription.
# -----------------------------------------------------------------------------
resource "aws_lambda_permission" "allow_sns_invoke" {
  statement_id  = "AllowSNSInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.efs_userspace_provisioner.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.user_events.arn
}

resource "aws_sns_topic_subscription" "user_events_to_lambda" {
  topic_arn = aws_sns_topic.user_events.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.efs_userspace_provisioner.arn
}

# -----------------------------------------------------------------------------
# 6. EventBridge reconcile schedule - 매시간.
#    Server 가 본 schedule 직접 응답할 수 없으므로 페이로드는 비어 있고,
#    Lambda 가 자체적으로 Server 의 list-users API 호출 (별도 구현 시) 또는
#    수동 reconcile 페이로드 발사 시점에만 동작. 현재는 hook 만 정의해 두고
#    실제 user_ids 페이로드는 운영자가 수동 발사.
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_event_rule" "userspace_reconcile" {
  name                = "${local.name_prefix}-efs-userspace-reconcile"
  description         = "매시간 reconcile (Server 측 user 목록 sync). 수동 payload 도 본 rule 사용."
  schedule_expression = "rate(1 hour)"
  state               = "DISABLED" # 초기에는 비활성. Server 측 list-users API 준비 후 운영자가 enable.

  tags = var.tags
}

resource "aws_lambda_permission" "allow_eventbridge_invoke" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.efs_userspace_provisioner.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.userspace_reconcile.arn
}

resource "aws_cloudwatch_event_target" "userspace_reconcile" {
  rule = aws_cloudwatch_event_rule.userspace_reconcile.name
  arn  = aws_lambda_function.efs_userspace_provisioner.arn

  # 빈 reconcile - 실제 사용은 운영자가 직접 invoke 또는 별도 rule 추가.
  input = jsonencode({ event = "user.reconcile", user_ids = [] })
}

# -----------------------------------------------------------------------------
# 7. IAM addendum - EC2 instance role 이 user_events SNS topic 에 publish 가능하게.
#    iam.tf 의 inline policy 가 이미 정의되어 있어 별도 statement 로 분리.
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "ec2_publish_user_events" {
  statement {
    sid       = "PublishUserEvents"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.user_events.arn]
  }
}

resource "aws_iam_role_policy" "ec2_publish_user_events" {
  name   = "${local.name_prefix}-ec2-publish-user-events"
  role   = aws_iam_role.ec2.id
  policy = data.aws_iam_policy_document.ec2_publish_user_events.json
}

# -----------------------------------------------------------------------------
# Outputs.
# -----------------------------------------------------------------------------
output "user_events_topic_arn" {
  description = "Server 가 회원 lifecycle 이벤트를 publish 할 SNS topic ARN."
  value       = aws_sns_topic.user_events.arn
}

output "efs_userspace_provisioner_function_name" {
  description = "수동 reconcile 호출 시 사용 (aws lambda invoke --function-name ...)."
  value       = aws_lambda_function.efs_userspace_provisioner.function_name
}
