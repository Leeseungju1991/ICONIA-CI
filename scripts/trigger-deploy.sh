#!/usr/bin/env bash
###############################################################################
# trigger-deploy.sh — EC2 인스턴스에 SSM Run Command 로 배포 트리거.
#
# trigger-deploy.ps1 (Windows 운영자용) 의 Linux/CI 등가물.
# build-and-upload.sh 가 S3 에 올린 최신 artifact 를 EC2 가 pull + restart 하게 한다.
# SSM AWS-RunShellScript 사용 — SSH 불필요.
#
# 사용법:
#   scripts/trigger-deploy.sh --service all [--instance-id i-xxxx] \
#     [--region ap-northeast-2] [--name-prefix iconia-prod] [--timeout 600]
#
# 환경변수 fallback: ICONIA_EC2_INSTANCE_ID, AWS_REGION
#
# Exit codes: 0 성공 / 1 배포 실패 / 2 사용법 오류 / 3 polling timeout
###############################################################################
set -euo pipefail

SERVICE="all"
INSTANCE_ID="${ICONIA_EC2_INSTANCE_ID:-}"
REGION="${AWS_REGION:-ap-northeast-2}"
NAME_PREFIX="iconia-prod"
TIMEOUT=600

while [ $# -gt 0 ]; do
  case "$1" in
    --service)      SERVICE="$2"; shift 2 ;;
    --instance-id)  INSTANCE_ID="$2"; shift 2 ;;
    --region)       REGION="$2"; shift 2 ;;
    --name-prefix)  NAME_PREFIX="$2"; shift 2 ;;
    --timeout)      TIMEOUT="$2"; shift 2 ;;
    -h|--help)      grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "ERR: unknown arg $1" >&2; exit 2 ;;
  esac
done

case "$SERVICE" in server|ai|admin|all) ;; *)
  echo "ERR: --service 는 server|ai|admin|all" >&2; exit 2 ;; esac
command -v aws >/dev/null || { echo "ERR: aws CLI 필요" >&2; exit 1; }

log() { printf '[deploy %s] %s\n' "$(date -u +%FT%TZ)" "$*"; }

# Instance 미지정 시 태그로 조회.
if [ -z "$INSTANCE_ID" ]; then
  log "InstanceId 미지정 — 태그(Name=${NAME_PREFIX}-host) 조회"
  ids="$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:Name,Values=${NAME_PREFIX}-host" "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].InstanceId' --output text)"
  count="$(echo "$ids" | wc -w)"
  [ "$count" -eq 0 ] && { echo "ERR: running 인스턴스 없음 (Name=${NAME_PREFIX}-host)" >&2; exit 1; }
  [ "$count" -gt 1 ] && { echo "ERR: 여러 인스턴스 매칭 — --instance-id 명시 필요: ${ids}" >&2; exit 1; }
  INSTANCE_ID="$ids"
  log "resolved InstanceId=${INSTANCE_ID}"
fi

# SSM SendCommand. SERVICE 는 화이트리스트 검증 완료 → 셸 인젝션 안전.
CMD="/usr/local/bin/iconia-pull-and-restart.sh ${SERVICE}"
PARAMS_FILE="$(mktemp)"
trap 'rm -f "$PARAMS_FILE"' EXIT
printf '{"commands":["%s"]}' "$CMD" > "$PARAMS_FILE"

log "SSM SendCommand -> ${INSTANCE_ID} : ${CMD}"
SEND="$(aws ssm send-command --region "$REGION" \
  --document-name 'AWS-RunShellScript' \
  --instance-ids "$INSTANCE_ID" \
  --comment "ICONIA deploy: ${SERVICE}" \
  --parameters "file://${PARAMS_FILE}" \
  --cloud-watch-output-config 'CloudWatchOutputEnabled=true' \
  --output json)"
CMD_ID="$(echo "$SEND" | jq -r '.Command.CommandId')"
log "CommandId=${CMD_ID}"

# Polling.
DEADLINE=$(( $(date +%s) + TIMEOUT ))
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  sleep 5
  INV="$(aws ssm get-command-invocation --region "$REGION" \
    --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" --output json 2>/dev/null || true)"
  [ -n "$INV" ] || continue
  STATUS="$(echo "$INV" | jq -r '.Status')"
  log "Status=${STATUS}"
  case "$STATUS" in
    Success)
      echo "==== STDOUT ===="; echo "$INV" | jq -r '.StandardOutputContent'
      exit 0 ;;
    Failed|Cancelled|TimedOut)
      echo "==== STDOUT ===="; echo "$INV" | jq -r '.StandardOutputContent'
      echo "==== STDERR ===="; echo "$INV" | jq -r '.StandardErrorContent'
      exit 1 ;;
  esac
done

echo "ERR: ${TIMEOUT}s 초과 — 콘솔에서 확인: aws ssm get-command-invocation --command-id ${CMD_ID} --instance-id ${INSTANCE_ID}" >&2
exit 3
