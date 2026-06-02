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

# -----------------------------------------------------------------------------
# SSM Automation Document — ASG rolling instance refresh (V1.0 신설).
#
# 사용 시나리오:
#   - 새 AMI 또는 user-data 변경 후 모든 ASG 인스턴스를 graceful 교체.
#   - 운영 중 메모리 누수/캐시 오염 의심 시 무중단 refresh.
#
# 동작:
#   1) ASG describe — 현재 상태 확인.
#   2) StartInstanceRefresh (min_healthy_percentage 90%, instance_warmup 180s).
#   3) ASG instance 교체 완료까지 대기.
#   4) SNS 알림.
#
# 본 Document 는 ALB target group 에 deregistration 30s drain 이 작동하는
# 것을 전제 — alb.tf 의 deregistration_delay 와 정합.
# -----------------------------------------------------------------------------
resource "aws_ssm_document" "asg_instance_refresh" {
  count           = var.create_failover_runbook ? 1 : 0
  name            = "${local.name_prefix}-asg-instance-refresh"
  document_type   = "Automation"
  document_format = "JSON"

  tags = merge(var.tags, { component = "dr-runbook" })

  content = jsonencode({
    schemaVersion = "0.3"
    description   = "ICONIA ASG rolling instance refresh — graceful drain + 신규 인스턴스 healthy 후 교체. 무중단 운영 가정."
    assumeRole    = "{{ AutomationAssumeRole }}"
    parameters = {
      AutoScalingGroupName = {
        type        = "String"
        description = "교체할 ASG 이름."
        default     = aws_autoscaling_group.iconia_server.name
      }
      MinHealthyPercentage = {
        type          = "String"
        description   = "교체 중 최소 healthy 비율(%). 90 권장 — 한 번에 인스턴스 1대씩 교체."
        default       = "90"
        allowedValues = ["50", "60", "70", "80", "90", "100"]
      }
      InstanceWarmup = {
        type        = "String"
        description = "신규 인스턴스 warmup 대기(초). user-data + npm ci + systemd 부팅 합산."
        default     = "300"
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
        name        = "describeBefore"
        action      = "aws:executeAwsApi"
        description = "현재 ASG 상태 / 인스턴스 수 / health 조회."
        inputs = {
          Service                = "autoscaling"
          Api                    = "DescribeAutoScalingGroups"
          AutoScalingGroupNames  = ["{{ AutoScalingGroupName }}"]
        }
        outputs = [
          { Name = "DesiredCapacity", Selector = "$.AutoScalingGroups[0].DesiredCapacity", Type = "Integer" },
          { Name = "MinSize", Selector = "$.AutoScalingGroups[0].MinSize", Type = "Integer" },
        ]
      },
      {
        name        = "startRefresh"
        action      = "aws:executeAwsApi"
        description = "rolling refresh 시작 — min_healthy 보장하며 인스턴스 교체."
        inputs = {
          Service              = "autoscaling"
          Api                  = "StartInstanceRefresh"
          AutoScalingGroupName = "{{ AutoScalingGroupName }}"
          Strategy             = "Rolling"
          Preferences = {
            MinHealthyPercentage = "{{ MinHealthyPercentage }}"
            InstanceWarmup       = "{{ InstanceWarmup }}"
          }
        }
        outputs = [
          { Name = "RefreshId", Selector = "$.InstanceRefreshId", Type = "String" },
        ]
      },
      {
        name        = "notifyResult"
        action      = "aws:executeAwsApi"
        isEnd       = true
        description = "결과를 SNS 로 통지. 운영자/PagerDuty 가 refresh 진행 timeline 확보."
        inputs = {
          Service  = "sns"
          Api      = "Publish"
          TopicArn = "{{ SnsTopicArn }}"
          Subject  = "ICONIA ASG instance refresh 시작"
          Message  = "ASG {{ AutoScalingGroupName }} instance refresh 시작됨. RefreshId={{ startRefresh.RefreshId }}, DesiredCapacity={{ describeBefore.DesiredCapacity }}. 진행 상황: aws autoscaling describe-instance-refreshes --auto-scaling-group-name {{ AutoScalingGroupName }} --instance-refresh-ids {{ startRefresh.RefreshId }}"
        }
      },
    ]
  })
}

# -----------------------------------------------------------------------------
# SSM Automation Document — Redis primary failover (V1.0 신설).
#
# 사용 시나리오:
#   - Redis primary node 장애 의심 시 replica → primary 강제 승격.
#   - Multi-AZ replication group 이라 자동 failover 도 작동하지만 분/초 단위 강제 시.
#
# 동작:
#   1) DescribeReplicationGroups — 현재 status 조회.
#   2) TestFailover (Redis OSS API) — replica 를 primary 로 승격.
#   3) SNS 통지.
# -----------------------------------------------------------------------------
resource "aws_ssm_document" "redis_failover" {
  count           = var.create_failover_runbook ? 1 : 0
  name            = "${local.name_prefix}-redis-failover"
  document_type   = "Automation"
  document_format = "JSON"

  tags = merge(var.tags, { component = "dr-runbook" })

  content = jsonencode({
    schemaVersion = "0.3"
    description   = "ICONIA Redis primary failover — Multi-AZ replication group 의 replica 를 primary 로 강제 승격."
    assumeRole    = "{{ AutomationAssumeRole }}"
    parameters = {
      ReplicationGroupId = {
        type        = "String"
        description = "대상 Redis replication group ID."
        default     = aws_elasticache_replication_group.iconia_redis.id
      }
      NodeGroupId = {
        type        = "String"
        description = "Failover 대상 node group ID. 단일 shard 면 '0001'."
        default     = "0001"
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
        name        = "describeBefore"
        action      = "aws:executeAwsApi"
        description = "현재 Redis replication group 상태 조회."
        inputs = {
          Service             = "elasticache"
          Api                 = "DescribeReplicationGroups"
          ReplicationGroupId  = "{{ ReplicationGroupId }}"
        }
        outputs = [
          { Name = "Status", Selector = "$.ReplicationGroups[0].Status", Type = "String" },
          { Name = "AutoFailover", Selector = "$.ReplicationGroups[0].AutomaticFailover", Type = "String" },
        ]
      },
      {
        name        = "testFailover"
        action      = "aws:executeAwsApi"
        description = "Replica → Primary 강제 승격 (multi-az enabled 가 전제)."
        inputs = {
          Service            = "elasticache"
          Api                = "TestFailover"
          ReplicationGroupId = "{{ ReplicationGroupId }}"
          NodeGroupId        = "{{ NodeGroupId }}"
        }
      },
      {
        name        = "notifyResult"
        action      = "aws:executeAwsApi"
        isEnd       = true
        description = "결과를 SNS 로 통지."
        inputs = {
          Service  = "sns"
          Api      = "Publish"
          TopicArn = "{{ SnsTopicArn }}"
          Subject  = "ICONIA Redis failover runbook 실행 완료"
          Message  = "Redis {{ ReplicationGroupId }} (NodeGroup {{ NodeGroupId }}) failover 시작됨. 시작 상태={{ describeBefore.Status }}, AutoFailover={{ describeBefore.AutoFailover }}. 60~120초 내 신규 primary endpoint 가 안정화. /health?deep=1 검증 필요."
        }
      },
    ]
  })
}

# Redis failover 권한 추가 — ssm_automation_inline 의 elasticache:TestFailover.
data "aws_iam_policy_document" "ssm_automation_redis_failover" {
  count = var.create_failover_runbook ? 1 : 0
  statement {
    sid       = "RedisTestFailover"
    actions   = ["elasticache:TestFailover"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "ssm_automation_redis_failover" {
  count  = var.create_failover_runbook ? 1 : 0
  name   = "${local.name_prefix}-ssm-redis-failover-inline"
  role   = aws_iam_role.ssm_automation[0].id
  policy = data.aws_iam_policy_document.ssm_automation_redis_failover[0].json
}

output "asg_instance_refresh_document" {
  description = "ASG rolling instance refresh SSM Automation Document 이름."
  value       = var.create_failover_runbook ? aws_ssm_document.asg_instance_refresh[0].name : ""
}

output "redis_failover_runbook_document" {
  description = "Redis primary failover SSM Automation Document 이름."
  value       = var.create_failover_runbook ? aws_ssm_document.redis_failover[0].name : ""
}
