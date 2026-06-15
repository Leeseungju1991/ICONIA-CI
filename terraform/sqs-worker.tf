###############################################################################
# sqs-worker.tf — 2026-06-15 (사용자 요청) Heavy AI 호출 비동기 분리 인프라.
#
# 정책:
#   · Gemini Vision / 대용량 첨부 분석 같은 동기 응답이 굳이 필요 없는 작업을
#     SQS Standard queue 로 위임. 처리 결과는 서버가 polling 으로 가져와
#     ChatMessage 에 lazy upsert.
#   · 운영 적용은 토글 (var.enable_ai_worker_queue). default=false.
#   · DLQ 함께 정의 — 5회 실패 시 DLQ 이동, CloudWatch alarm.
#
# 다음 라운드 필요 작업:
#   1) `2. SERVER/src/services/chatService.js` — 비동기 분기 (sendUserMessage 의
#      isHeavyAttachment 분기 추가) → enqueue + 200 응답 (kind: 'queued').
#   2) `2. SERVER/src/workers/aiHeavyWorker.js` — SQS 메시지 polling + AI 호출 + DB upsert.
#      systemd unit 별도 (iconia-ai-worker) 또는 ECS task.
#   3) App side — 결과 polling endpoint 도입 (GET /chat/messages/{id}/result).
#
# 비용 (대략):
#   · Standard queue: $0.40 per 1M (첫 1M 무료/월)
#   · DLQ 운영: $0.40 per 1M
#   · 보통 트래픽에선 $1~5/월 수준.
###############################################################################

variable "enable_ai_worker_queue" {
  description = "AI heavy work 비동기 처리용 SQS queue 활성화. true 로 설정 시 plan/apply 적용."
  type        = bool
  default     = false
}

# -----------------------------------------------------------------------------
# Dead Letter Queue.
# -----------------------------------------------------------------------------
resource "aws_sqs_queue" "ai_heavy_dlq" {
  count = var.enable_ai_worker_queue ? 1 : 0

  name                       = "${local.name_prefix}-ai-heavy-dlq"
  message_retention_seconds  = 1209600 # 14d — 분석 시간 확보.
  visibility_timeout_seconds = 60

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-ai-heavy-dlq"
  })
}

# -----------------------------------------------------------------------------
# Primary Standard queue.
# -----------------------------------------------------------------------------
resource "aws_sqs_queue" "ai_heavy" {
  count = var.enable_ai_worker_queue ? 1 : 0

  name = "${local.name_prefix}-ai-heavy"

  # 60s — Gemini Vision 단일 호출 timeout 정합.
  visibility_timeout_seconds = 60
  message_retention_seconds  = 86400 # 1d — 오래된 메시지는 stale.
  receive_wait_time_seconds  = 10    # long polling — 비용 최적화.

  # 5회 실패 시 DLQ 이동.
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.ai_heavy_dlq[0].arn
    maxReceiveCount     = 5
  })

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-ai-heavy"
  })
}

# -----------------------------------------------------------------------------
# DLQ 적체 알람 — 1건 이상 발생 즉시 알림.
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "ai_heavy_dlq_messages" {
  count = var.enable_ai_worker_queue ? 1 : 0

  alarm_name          = "${local.name_prefix}-ai-heavy-dlq-spike"
  alarm_description   = "AI heavy work DLQ 에 메시지 적체 — Worker 실패 / Gemini 차단 / 입력 검증 실패 의심."
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  threshold           = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 300
  statistic           = "Maximum"
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = aws_sqs_queue.ai_heavy_dlq[0].name
  }

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-ai-heavy-dlq-spike"
  })
}

# -----------------------------------------------------------------------------
# Worker IAM Role — EC2 worker 가 큐 receive/delete + S3 read + CloudWatch put.
# -----------------------------------------------------------------------------
resource "aws_iam_role" "ai_heavy_worker" {
  count = var.enable_ai_worker_queue ? 1 : 0

  name = "${local.name_prefix}-ai-heavy-worker-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-ai-heavy-worker-role"
  })
}

resource "aws_iam_role_policy" "ai_heavy_worker_policy" {
  count = var.enable_ai_worker_queue ? 1 : 0

  name = "${local.name_prefix}-ai-heavy-worker-policy"
  role = aws_iam_role.ai_heavy_worker[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
          "sqs:ChangeMessageVisibility",
        ]
        Resource = [
          aws_sqs_queue.ai_heavy[0].arn,
          aws_sqs_queue.ai_heavy_dlq[0].arn,
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "cloudwatch:PutMetricData",
        ]
        Resource = "*"
      },
    ]
  })
}

# -----------------------------------------------------------------------------
# Server IAM 확장 — 기존 EC2 instance role 에 SQS Send 권한 추가.
#   (실 적용은 iam.tf 의 iconia_server_role 에 attach 정책 첨가 필요 — 별도 PR.)
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "ai_heavy_send" {
  count = var.enable_ai_worker_queue ? 1 : 0

  statement {
    effect = "Allow"
    actions = [
      "sqs:SendMessage",
      "sqs:GetQueueAttributes",
    ]
    resources = [aws_sqs_queue.ai_heavy[0].arn]
  }
}

resource "aws_iam_policy" "ai_heavy_send" {
  count = var.enable_ai_worker_queue ? 1 : 0

  name        = "${local.name_prefix}-ai-heavy-send"
  description = "Allow server EC2 to enqueue AI heavy work."
  policy      = data.aws_iam_policy_document.ai_heavy_send[0].json

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-ai-heavy-send"
  })
}

# -----------------------------------------------------------------------------
# Outputs — server/worker 가 ENV 로 큐 URL 을 읽도록.
# -----------------------------------------------------------------------------
output "ai_heavy_queue_url" {
  description = "AI heavy work SQS queue URL (enable_ai_worker_queue=true 시)."
  value       = var.enable_ai_worker_queue ? aws_sqs_queue.ai_heavy[0].url : null
}

output "ai_heavy_dlq_url" {
  description = "AI heavy work DLQ URL (enable_ai_worker_queue=true 시)."
  value       = var.enable_ai_worker_queue ? aws_sqs_queue.ai_heavy_dlq[0].url : null
}

output "ai_heavy_worker_role_arn" {
  description = "Worker EC2/ECS 에 부여할 IAM Role ARN."
  value       = var.enable_ai_worker_queue ? aws_iam_role.ai_heavy_worker[0].arn : null
}
