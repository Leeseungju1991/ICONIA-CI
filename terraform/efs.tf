###############################################################################
# efs.tf - Persona 4층 기억(결정화/장기 관계) 영속 저장소.
#
# 페르소나 명세상 사용자별 SOUL 격리가 절대 제약. 본 EFS 는 file system 1개를
# 사용자 디렉토리(또는 access point) 로 분할하여 격리한다. 본 스캐폴드는 file
# system + 단일 access point + mount target 만 정의 - 사용자별 access point 는
# 운영팀이 추가 stack 으로 자동화 (수가 많아 IaC 의 적정 단위 아님).
###############################################################################

resource "aws_efs_file_system" "persona" {
  creation_token  = "${local.name_prefix}-persona-efs"
  encrypted       = true
  throughput_mode = var.efs_throughput_mode

  lifecycle_policy {
    transition_to_ia = "AFTER_30_DAYS"
  }
  lifecycle_policy {
    transition_to_primary_storage_class = "AFTER_1_ACCESS"
  }

  tags = merge(var.tags, { Name = "${local.name_prefix}-persona-efs" })
}

resource "aws_efs_backup_policy" "persona" {
  file_system_id = aws_efs_file_system.persona.id
  backup_policy {
    status = "ENABLED" # 페르소나 결정화 기억 손실은 사용자 입장에서 "인형이 기억을 잃었다"로 직결.
  }
}

# Mount target - private subnet 마다 한 개.
# for_each key 는 var.azs (static input) — plan time 에 cardinality 결정.
# value 는 인덱스 정수 → aws_subnet.private[each.value].id 로 subnet 참조.
# 이전 `toset(local.private_subnet_ids)` 패턴은 fresh state 에서 subnet id 가 unknown
# 이라 plan time 에 for_each cardinality 결정 불가 → 신 계정 migration 시 plan 실패.
resource "aws_efs_mount_target" "persona" {
  for_each        = { for idx, az in var.azs : az => idx }
  file_system_id  = aws_efs_file_system.persona.id
  subnet_id       = aws_subnet.private[each.value].id
  security_groups = [aws_security_group.efs.id]
}

# Access point - server 공통 root. 사용자별 격리는 디렉토리 + posix uid/gid 로 추가.
resource "aws_efs_access_point" "server_root" {
  file_system_id = aws_efs_file_system.persona.id

  posix_user {
    gid = 1000
    uid = 1000
  }

  root_directory {
    path = "/iconia"
    creation_info {
      owner_gid   = 1000
      owner_uid   = 1000
      permissions = "0750"
    }
  }

  tags = merge(var.tags, { purpose = "server-root" })
}
