###############################################################################
# quotas-auto-lift.tf (Round 2026-05-26, Task #11)
#
# GCP Cloud Quotas 자동 증설 신청 Lambda + EventBridge weekly cron.
#
# 본 라운드는 "준비" 단계 — 운영자가 활성화 결정을 내릴 때까지 schedule 은
# DISABLED 로 시작한다. 활성화 절차:
#
#   1) GCP IAM 콘솔에서 service account 발급:
#      - role: roles/cloudquotas.admin (최소).
#      - JSON 키 생성 후 다운로드.
#
#   2) Secrets Manager 에 JSON 본문 등록:
#      aws secretsmanager create-secret \
#        --name iconia/${env}/gcp/service_account_json \
#        --secret-string file://gcp-sa-iconia.json
#
#   3) terraform.tfvars 에 토글:
#      enable_quotas_auto_lift = true
#      gcp_project_id          = "iconia-prod-457912"
#
#   4) terraform apply.
#
# Lambda 자체는 항상 생성된다 (수동 invoke 로 dry-run 가능).
# schedule 만 enable_quotas_auto_lift 토글로 controlled.
#
# 비용: Lambda 주간 1회 invocation → 무료. Secrets Manager 조회 월 4회 → < $0.01.
#
# 자동 승인 불가 — Google 측 manual review (1~3 영업일).
# 본 Lambda 는 "신청 트리거" 만 자동화. 결과 polling 은 별도 운영 절차
# (deploy/RUNBOOK.md 의 quotas section 참조 — 본 라운드 미작성).
###############################################################################

# -----------------------------------------------------------------------------
# 변수.
# -----------------------------------------------------------------------------
variable "enable_quotas_auto_lift" {
  description = "GCP Cloud Quotas auto-lift Lambda 의 weekly cron 활성 여부. false 면 Lambda 만 생성 (수동 invoke 가능), cron 은 DISABLED."
  type        = bool
  default     = false
}

variable "gcp_project_id" {
  description = "GCP project id (Gemini API 사용 프로젝트). enable_quotas_auto_lift=true 일 때 필수."
  type        = string
  default     = ""
}

variable "gcp_quotas_sa_secret_name" {
  description = "Secrets Manager 의 GCP service account JSON secret 이름. 기본값은 iconia/${var.env}/gcp/service_account_json."
  type        = string
  default     = ""
}

variable "quotas_target_limit_name" {
  description = "Cloud Quotas API 의 limit name. Gemini API request rate."
  type        = string
  default     = "GenerateContentRequestsPerMinutePerProject"
}

variable "quotas_multiplier" {
  description = "Baseline → 신청값 배수. persona-ai 권장 = 2 (200%)."
  type        = number
  default     = 2
}

variable "quotas_hard_ceiling" {
  description = "최종 안전 상한 (RPM). Lambda 가 절대 넘기지 않음. Gemini 측 max quota 정책에 맞춰 조정."
  type        = number
  default     = 10000
}

variable "quotas_cron_expression" {
  description = "EventBridge cron — 기본 매주 일요일 00:00 UTC. weekly = 신청 누적 + Google review 1~3일 = 다음 일요일 전 결과 확정."
  type        = string
  default     = "cron(0 0 ? * SUN *)"
}

locals {
  quotas_sa_secret_effective = (
    var.gcp_quotas_sa_secret_name != ""
    ? var.gcp_quotas_sa_secret_name
    : "iconia/${var.env}/gcp/service_account_json"
  )
}

# -----------------------------------------------------------------------------
# Lambda 패키징.
# -----------------------------------------------------------------------------
data "archive_file" "gcp_quotas_auto_lift" {
  type        = "zip"
  source_file = "${path.module}/lambda/gcp_quotas_auto_lift.py"
  output_path = "${path.module}/.terraform/lambda-gcp-quotas-auto-lift.zip"
}

# -----------------------------------------------------------------------------
# IAM role.
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "gcp_quotas_auto_lift_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "gcp_quotas_auto_lift" {
  name               = "${local.name_prefix}-gcp-quotas-auto-lift-role"
  assume_role_policy = data.aws_iam_policy_document.gcp_quotas_auto_lift_assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "gcp_quotas_auto_lift_inline" {
  # GCP service account JSON 1건 조회. resource arn 을 정확히 명시해 최소권한.
  statement {
    sid     = "SecretsManagerReadGcpSa"
    actions = ["secretsmanager:GetSecretValue"]
    resources = [
      "arn:aws:secretsmanager:${local.region}:${local.account_id}:secret:${local.quotas_sa_secret_effective}*",
    ]
  }

  statement {
    sid     = "CloudWatchMetrics"
    actions = ["cloudwatch:PutMetricData"]
    # PutMetricData 는 resource-level 권한이 없어 * 만 사용 — IAM condition 으로 namespace 좁힘.
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = ["ICONIA/Quotas"]
    }
  }

  statement {
    sid = "CloudWatchLogs"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = [
      "arn:aws:logs:${local.region}:${local.account_id}:log-group:/aws/lambda/${local.name_prefix}-gcp-quotas-auto-lift*",
    ]
  }
}

resource "aws_iam_role_policy" "gcp_quotas_auto_lift_inline" {
  name   = "${local.name_prefix}-gcp-quotas-auto-lift-inline"
  role   = aws_iam_role.gcp_quotas_auto_lift.id
  policy = data.aws_iam_policy_document.gcp_quotas_auto_lift_inline.json
}

# -----------------------------------------------------------------------------
# Lambda function.
#
# 본 Lambda 는 google-auth + google-api-python-client 가 필요 (Python).
# packaging 옵션 2가지:
#   a) Lambda layer — 운영자가 한 번만 build 후 ARN 을 var 로 주입.
#   b) zip 동봉 — pip install -t ./lambda/_deps 후 archive_file 으로 묶음.
#
# 본 라운드는 (b) 의 helper 만 안내 (README 참조). archive_file 은 단일
# .py 만 묶는다 — deps 미포함 → 첫 invoke 는 ImportError. 운영자가 명시적으로
# layer/deps 를 준비해야 활성화 가능 (의도된 fail-fast).
# -----------------------------------------------------------------------------
resource "aws_lambda_function" "gcp_quotas_auto_lift" {
  function_name = "${local.name_prefix}-gcp-quotas-auto-lift"
  role          = aws_iam_role.gcp_quotas_auto_lift.arn
  runtime       = "python3.12"
  handler       = "gcp_quotas_auto_lift.lambda_handler"
  timeout       = 60
  memory_size   = 256

  filename         = data.archive_file.gcp_quotas_auto_lift.output_path
  source_code_hash = data.archive_file.gcp_quotas_auto_lift.output_base64sha256

  # google-auth + google-api-python-client layer 가 필요. 운영자가 빌드 후 ARN 주입.
  # 미설정 → 첫 invoke 가 ImportError 로 명시 실패 (Lambda 로그에 _IMPORT_ERROR 노출).
  # layers = [var.gcp_python_deps_layer_arn]

  environment {
    variables = {
      GCP_PROJECT_ID          = var.gcp_project_id
      GCP_SA_SECRET_NAME      = local.quotas_sa_secret_effective
      QUOTA_TARGET_LIMIT_NAME = var.quotas_target_limit_name
      QUOTA_MULTIPLIER        = tostring(var.quotas_multiplier)
      QUOTA_HARD_CEILING      = tostring(var.quotas_hard_ceiling)
      LOG_LEVEL               = "INFO"
    }
  }

  tags = merge(var.tags, { purpose = "gcp-quotas-auto-lift" })
}

# -----------------------------------------------------------------------------
# EventBridge weekly cron.
#
# enable_quotas_auto_lift=false 면 state=DISABLED — rule 은 생성하되 발화 안 함.
# 운영자가 활성화 결정을 내릴 때 토글만 바꾸면 됨 (Lambda 본체는 항상 있음).
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_event_rule" "gcp_quotas_auto_lift_weekly" {
  name                = "${local.name_prefix}-gcp-quotas-auto-lift-weekly"
  description         = "Weekly GCP Cloud Quotas auto-lift trigger (Round 2026-05-26 Task #11). Google manual review 1-3 business days."
  schedule_expression = var.quotas_cron_expression
  state               = var.enable_quotas_auto_lift ? "ENABLED" : "DISABLED"
  tags                = var.tags
}

resource "aws_cloudwatch_event_target" "gcp_quotas_auto_lift_weekly" {
  rule      = aws_cloudwatch_event_rule.gcp_quotas_auto_lift_weekly.name
  target_id = "gcp-quotas-auto-lift-lambda"
  arn       = aws_lambda_function.gcp_quotas_auto_lift.arn
}

resource "aws_lambda_permission" "allow_eventbridge_invoke_quotas" {
  statement_id  = "AllowEventBridgeInvokeQuotasAutoLift"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.gcp_quotas_auto_lift.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.gcp_quotas_auto_lift_weekly.arn
}

# -----------------------------------------------------------------------------
# Outputs — 운영자 콘솔 / runbook 참조용.
# -----------------------------------------------------------------------------
output "gcp_quotas_auto_lift_function_name" {
  description = "GCP Cloud Quotas auto-lift Lambda 이름. 수동 invoke: aws lambda invoke --function-name <name> /tmp/out.json"
  value       = aws_lambda_function.gcp_quotas_auto_lift.function_name
}

output "gcp_quotas_auto_lift_schedule_state" {
  description = "Weekly cron state. false → DISABLED (운영자가 활성화 결정 시 toggle)."
  value       = aws_cloudwatch_event_rule.gcp_quotas_auto_lift_weekly.state
}
