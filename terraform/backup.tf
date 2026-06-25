###############################################################################
# backup.tf — AWS Backup vault + 7-day rolling plan (REQ#3-2).
#
# 대상: aws_db_instance.postgres (primary) + aws_db_instance.postgres_backup (replica)
# 스케줄: 매일 02:00 KST (UTC 17:00) — backup_window 와 겹치지 않도록 backup_window
#         17:00-18:00 이후가 아닌 cron(0 17 ...) 동시 진입이지만 AWS Backup 이
#         RDS 자동 백업과 독립 snapshot 을 생성하므로 충돌하지 않는다.
# 보존: 7일 이후 자동 삭제.
###############################################################################

resource "aws_backup_vault" "iconia" {
  name = "iconia-prod-vault"
  tags = merge(var.tags, { component = "backup" })
}

resource "aws_backup_plan" "weekly7d" {
  name = "iconia-rds-weekly7d"

  rule {
    rule_name         = "daily-rds-7d"
    target_vault_name = aws_backup_vault.iconia.name
    schedule          = "cron(0 17 * * ? *)" # 02:00 KST daily

    lifecycle {
      delete_after = 7
    }

    start_window      = 60
    completion_window = 180
  }

  tags = merge(var.tags, { component = "backup" })
}

resource "aws_iam_role" "aws_backup" {
  name = "iconia-aws-backup-service-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "backup.amazonaws.com" }
    }]
  })

  tags = merge(var.tags, { component = "backup" })
}

resource "aws_iam_role_policy_attachment" "aws_backup_default" {
  role       = aws_iam_role.aws_backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

resource "aws_backup_selection" "rds" {
  name         = "iconia-rds-selection"
  iam_role_arn = aws_iam_role.aws_backup.arn
  plan_id      = aws_backup_plan.weekly7d.id

  resources = compact([
    try(aws_db_instance.postgres[0].arn, null),
    try(aws_db_instance.postgres_backup[0].arn, null),
  ])
}
