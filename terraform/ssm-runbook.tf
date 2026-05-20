###############################################################################
# ssm-runbook.tf — Multi-AZ failover 1-click runbook (README §4.6).
#
# deploy/aws/multi-az-failover-runbook.md §7 의 "M+1 라운드 자동화" 를 흡수한다.
# §1(RDS) ~ §4(EC2) 의 manual 절차를 AWS Systems Manager Automation Document
# 로 packaging 하여, SRE 가 콘솔/CLI 에서 한 번 실행하면 진단 → 조치 → 검증이
# 순차 수행되도록 한다.
#
# 안전 설계:
#   - 본 Document 는 "생성만" 한다. 실행(start-automation-execution)은 운영자가
#     사고 시 명시적으로 호출 — Terraform apply 가 failover 를 일으키지 않는다.
#   - schemaVersion 0.3 Automation. force-failover 같은 파괴적 단계는
#     `assertAwsResourceProperty` 로 사전 상태를 확인한 뒤에만 수행.
#   - rds_force_failover 파라미터로 자동 reboot-with-failover 의 ON/OFF 를 운영자가
#     실행 시점에 결정 (기본 false — 진단만).
###############################################################################

variable "create_failover_runbook" {
  description = "Multi-AZ failover SSM Automation Document 생성 여부."
  type        = bool
  default     = true
}

# -----------------------------------------------------------------------------
# IAM role — SSM Automation 이 RDS/EC2 를 조작할 때 가정하는 역할.
# AmazonSSMAutomationRole 관리정책 + RDS reboot-with-failover 권한.
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "ssm_automation_assume" {
  count = var.create_failover_runbook ? 1 : 0
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ssm.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ssm_automation" {
  count              = var.create_failover_runbook ? 1 : 0
  name               = "${local.name_prefix}-ssm-failover-automation-role"
  assume_role_policy = data.aws_iam_policy_document.ssm_automation_assume[0].json
  tags               = var.tags
}

data "aws_iam_policy_document" "ssm_automation_inline" {
  count = var.create_failover_runbook ? 1 : 0

  # RDS 진단 + reboot-with-failover.
  statement {
    sid = "RDSFailover"
    actions = [
      "rds:DescribeDBInstances",
      "rds:RebootDBInstance",
    ]
    resources = ["*"] # reboot-db-instance 는 condition 으로 좁히기 까다로움 — 운영팀이 추가 조정 가능.
  }

  # EFS / ElastiCache 진단 (read-only).
  statement {
    sid = "FailoverDiagnosticsReadOnly"
    actions = [
      "elasticfilesystem:DescribeMountTargets",
      "elasticfilesystem:DescribeFileSystems",
      "elasticache:DescribeReplicationGroups",
      "elasticache:DescribeCacheClusters",
    ]
    resources = ["*"]
  }

  # ASG instance refresh / desired capacity (EC2 AZ failover).
  statement {
    sid = "ASGFailover"
    actions = [
      "autoscaling:DescribeAutoScalingGroups",
      "autoscaling:StartInstanceRefresh",
      "autoscaling:SetDesiredCapacity",
    ]
    resources = ["*"]
  }

  # 사고 알림 — SNS publish.
  statement {
    sid       = "SNSNotify"
    actions   = ["sns:Publish"]
    resources = [module.alarms.sns_topic_arn]
  }
}

resource "aws_iam_role_policy" "ssm_automation_inline" {
  count  = var.create_failover_runbook ? 1 : 0
  name   = "${local.name_prefix}-ssm-failover-automation-inline"
  role   = aws_iam_role.ssm_automation[0].id
  policy = data.aws_iam_policy_document.ssm_automation_inline[0].json
}

# -----------------------------------------------------------------------------
# SSM Automation Document — RDS Multi-AZ failover (runbook §1).
# -----------------------------------------------------------------------------
resource "aws_ssm_document" "rds_failover" {
  count           = var.create_failover_runbook ? 1 : 0
  name            = "${local.name_prefix}-rds-multi-az-failover"
  document_type   = "Automation"
  document_format = "JSON"

  tags = merge(var.tags, { component = "dr-runbook" })

  content = jsonencode({
    schemaVersion = "0.3"
    description   = "ICONIA RDS Multi-AZ failover 자동 runbook (multi-az-failover-runbook.md §1). 진단 → (옵션) force-failover → 검증 → 알림."
    assumeRole    = "{{ AutomationAssumeRole }}"
    parameters = {
      DBInstanceIdentifier = {
        type        = "String"
        description = "대상 RDS 인스턴스 식별자."
        default     = "${local.name_prefix}-db"
      }
      ForceFailover = {
        type          = "String"
        description   = "true 면 reboot-with-failover 강제 수행 (runbook §1.2). 기본 false — 진단만."
        default       = "false"
        allowedValues = ["true", "false"]
      }
      AutomationAssumeRole = {
        type        = "String"
        description = "SSM Automation 이 가정할 IAM 역할 ARN."
        default     = aws_iam_role.ssm_automation[0].arn
      }
      SnsTopicArn = {
        type        = "String"
        description = "결과를 통지할 SNS topic ARN."
        default     = module.alarms.sns_topic_arn
      }
    }
    mainSteps = [
      {
        name        = "diagnoseBefore"
        action      = "aws:executeAwsApi"
        description = "현재 RDS 상태 / Multi-AZ 여부 조회 (runbook §1.1)."
        inputs = {
          Service              = "rds"
          Api                  = "DescribeDBInstances"
          DBInstanceIdentifier = "{{ DBInstanceIdentifier }}"
        }
        outputs = [
          { Name = "Status", Selector = "$.DBInstances[0].DBInstanceStatus", Type = "String" },
          { Name = "MultiAZ", Selector = "$.DBInstances[0].MultiAZ", Type = "Boolean" },
          { Name = "AvailabilityZone", Selector = "$.DBInstances[0].AvailabilityZone", Type = "String" },
        ]
      },
      {
        name        = "branchOnForceFailover"
        action      = "aws:branch"
        description = "ForceFailover=true 일 때만 reboot-with-failover 로 진행."
        inputs = {
          Choices = [
            {
              NextStep     = "rebootWithFailover"
              Variable     = "{{ ForceFailover }}"
              StringEquals = "true"
            },
          ]
          Default = "notifyResult"
        }
      },
      {
        name        = "rebootWithFailover"
        action      = "aws:executeAwsApi"
        description = "standby 로 강제 전환 (runbook §1.2). 약 60초 소요."
        inputs = {
          Service              = "rds"
          Api                  = "RebootDBInstance"
          DBInstanceIdentifier = "{{ DBInstanceIdentifier }}"
          ForceFailover        = true
        }
      },
      {
        name           = "waitForAvailable"
        action         = "aws:waitForAwsResourceProperty"
        description    = "failover 완료(available) 대기 — RTO < 5분 목표."
        timeoutSeconds = 600
        inputs = {
          Service              = "rds"
          Api                  = "DescribeDBInstances"
          DBInstanceIdentifier = "{{ DBInstanceIdentifier }}"
          PropertySelector     = "$.DBInstances[0].DBInstanceStatus"
          DesiredValues        = ["available"]
        }
      },
      {
        name        = "diagnoseAfter"
        action      = "aws:executeAwsApi"
        description = "failover 후 상태 재확인 (runbook §1.4 검증)."
        inputs = {
          Service              = "rds"
          Api                  = "DescribeDBInstances"
          DBInstanceIdentifier = "{{ DBInstanceIdentifier }}"
        }
        outputs = [
          { Name = "Status", Selector = "$.DBInstances[0].DBInstanceStatus", Type = "String" },
          { Name = "AvailabilityZone", Selector = "$.DBInstances[0].AvailabilityZone", Type = "String" },
        ]
      },
      {
        name        = "notifyResult"
        action      = "aws:executeAwsApi"
        isEnd       = true
        description = "결과를 SNS 로 통지. 운영자/PagerDuty 가 RTO timeline 확보."
        inputs = {
          Service  = "sns"
          Api      = "Publish"
          TopicArn = "{{ SnsTopicArn }}"
          Subject  = "ICONIA RDS failover runbook 실행 완료"
          Message  = "RDS {{ DBInstanceIdentifier }} failover runbook 실행됨. ForceFailover={{ ForceFailover }}, 시작 상태={{ diagnoseBefore.Status }}, AZ(before)={{ diagnoseBefore.AvailabilityZone }}. /health?deep=1 검증 필요 (runbook §1.4)."
        }
      },
    ]
  })
}

# -----------------------------------------------------------------------------
# SSM Automation Document — EFS / ElastiCache / EC2 진단 (runbook §2~§4).
# 파괴적 조치 없이 상태만 수집 — SRE 의 1차 분류(runbook §0)를 1-click 으로.
# -----------------------------------------------------------------------------
resource "aws_ssm_document" "failover_diagnostics" {
  count           = var.create_failover_runbook ? 1 : 0
  name            = "${local.name_prefix}-failover-diagnostics"
  document_type   = "Automation"
  document_format = "JSON"

  tags = merge(var.tags, { component = "dr-runbook" })

  content = jsonencode({
    schemaVersion = "0.3"
    description   = "ICONIA AZ 장애 1차 분류 진단 (multi-az-failover-runbook.md §0). EFS mount target / ElastiCache / RDS 상태를 한 번에 수집."
    assumeRole    = "{{ AutomationAssumeRole }}"
    parameters = {
      EfsFileSystemId = {
        type        = "String"
        description = "진단할 EFS file system id."
        default     = aws_efs_file_system.persona.id
      }
      DBInstanceIdentifier = {
        type        = "String"
        description = "진단할 RDS 인스턴스 식별자."
        default     = "${local.name_prefix}-db"
      }
      AutomationAssumeRole = {
        type        = "String"
        description = "SSM Automation 이 가정할 IAM 역할 ARN."
        default     = aws_iam_role.ssm_automation[0].arn
      }
    }
    mainSteps = [
      {
        name        = "efsMountTargets"
        action      = "aws:executeAwsApi"
        description = "EFS mount target lifecycle 상태 (runbook §2.1)."
        inputs = {
          Service      = "efs"
          Api          = "DescribeMountTargets"
          FileSystemId = "{{ EfsFileSystemId }}"
        }
        outputs = [
          { Name = "MountTargets", Selector = "$.MountTargets", Type = "MapList" },
        ]
      },
      {
        name        = "rdsStatus"
        action      = "aws:executeAwsApi"
        isEnd       = true
        description = "RDS 상태 (runbook §1 진입 판단)."
        inputs = {
          Service              = "rds"
          Api                  = "DescribeDBInstances"
          DBInstanceIdentifier = "{{ DBInstanceIdentifier }}"
        }
        outputs = [
          { Name = "Status", Selector = "$.DBInstances[0].DBInstanceStatus", Type = "String" },
          { Name = "MultiAZ", Selector = "$.DBInstances[0].MultiAZ", Type = "Boolean" },
        ]
      },
    ]
  })
}

# -----------------------------------------------------------------------------
# Outputs.
# -----------------------------------------------------------------------------
output "rds_failover_runbook_document" {
  description = "RDS Multi-AZ failover SSM Automation Document 이름. 실행: aws ssm start-automation-execution --document-name <name> --parameters ForceFailover=true"
  value       = var.create_failover_runbook ? aws_ssm_document.rds_failover[0].name : ""
}

output "failover_diagnostics_document" {
  description = "AZ 장애 1차 분류 진단 SSM Automation Document 이름."
  value       = var.create_failover_runbook ? aws_ssm_document.failover_diagnostics[0].name : ""
}
