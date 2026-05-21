###############################################################################
# ec2.tf — (Phase 6 이전) 단일 EC2 인스턴스 정의 제거됨.
#
# Phase 6 부터:
#   - AMI 조회 / user_data 템플릿: launch_template.tf
#   - ASG (desired=2~6, Multi-AZ): asg.tf
#   - ALB + target group + listener: alb.tf
#   - EIP 제거 (ALB DNS 가 Route53 alias 의 대상)
#
# 본 파일은 의도적으로 빈 placeholder 로 둔다. 단일 인스턴스 정의를 다시
# 도입하면 ASG 와 충돌하므로 절대 추가 금지.
#
# 마이그레이션:
#   1) `terraform state mv aws_instance.main aws_launch_template.iconia_server`
#      는 의미가 다르므로 사용 금지. 단일 인스턴스는 destroy 후 ASG 가 신규
#      인스턴스를 띄운다.
#   2) `terraform state rm aws_instance.main aws_eip.main` 으로 state 에서만
#      분리 → 콘솔에서 수동 종료 또는 destroy.
#   3) Route53 A record 가 ALB alias 로 전환되면 EIP 는 release.
###############################################################################
