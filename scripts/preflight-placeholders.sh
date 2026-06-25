#!/usr/bin/env bash
###############################################################################
# preflight-placeholders.sh
#
# 6개 폴더(1. HW / 2. SERVER / 3. AI / 4. APP / 5. ADMIN / 6. CI) 횡단으로
# 미채워진 placeholder 가 남아있는지 검사. release tag CI 가 호출하며 발견 시
# exit 1 로 release 차단.
#
# 사용법:
#   scripts/preflight-placeholders.sh [<repo_root>]
#     <repo_root> 미지정 시 본 스크립트의 ../../  (ICONIA root) 가정.
#
# Exit codes:
#   0  placeholder 미발견.
#   1  placeholder 발견 (파일:라인 + 패턴 출력).
#   2  사용법 오류 (root 없음 등).
#
# Ignore 정책:
#   - <repo_root>/6. CI/.preflightignore (gitignore 형식 glob) 자동 로드.
#   - 추가로 EXCLUDE_GLOBS 의 내장 fallback 도 항상 적용.
###############################################################################
set -euo pipefail

# placeholder 패턴 - 각 패턴별로 grep 후 결과 합산.
# 첫 7 개는 fixed-string, 그 뒤는 regex (마지막 컬럼 'R' 표시로 분기).
# 형식: "PATTERN|MODE"   (MODE=F fixed, R regex)
PATTERNS_SPEC=(
  "ICONIA_PROD_DOMAIN_PLACEHOLDER|F"
  "PROD_API_KEY_PLACEHOLDER|F"
  "iconia-tfstate-PLACEHOLDER|F"
  "__FILL_ME__|F"
  "__SET_IN_RENDER_DASHBOARD__|F"
  "CHANGE_ME|F"
  "PAIRING_TOKEN_PENDING|F"
  # === 추가 패턴 (2026-05-19) ===
  "your-domain-here|F"
  "REPLACE_WITH_|F"
  "__SET_BY_EAS_SECRET__|F"
  "TODO\(prod\)|R"
  "XXXXXX+|R"
  "<replace[^>]*here>|R"
  "INSERT_[A-Z0-9_]+_HERE|R"
  # NOTE: example.com URL 패턴은 false positive 폭주 (env 템플릿 문서/test 코드)로 제외.
  #       필요 시 별도 lint 로 분리. 본 preflight 는 release-blocker 신호만 유지.
)

# --- 약관/사업자정보 placeholder 패턴 (2026-05-26 추가) -----------------------
# (주)숨코리아 약관 본문 / 사업자정보 정본의 placeholder 가 prod 빌드에 새는 사고
# 차단용. 본 패턴은 docs/CHANGELOG/README ignore 와 별개로, 아래 LEGAL_SUBPATHS
# (legal config / 약관 본문) 에 한해 강제 검사된다.
LEGAL_PATTERNS_SPEC=(
  "__TBD__|F"
  "__PLACEHOLDER__|F"
  "XXX-XX-XXXXX|F"
  "Soom Korea Inc. (placeholder)|F"
)

# 6 레포 횡단으로 강제 검사할 약관/사업자정보 정본 경로 (ROOT/<repo>/<subpath>).
# - docs/legal/                  : SERVER/HW 등의 약관·DPIA·사업자정보 정본
# - src/config/legal.            : APP 의 사업자정보 코드 (legal.ts / legal.js)
# - src/legal/                   : 임의 레포의 legal 모듈
# - app.config.ts / app.config.js: APP/ADMIN expo/next 설정의 회사명·URL 잔존
# README.md 도 약관 회사명 잔존 사고 잦은 위치라 본 패스에서는 검사 대상.
LEGAL_SUBPATHS=(
  "docs/legal"
  "src/config/legal.ts"
  "src/config/legal.js"
  "src/config/legal.tsx"
  "src/legal"
  "app.config.ts"
  "app.config.js"
  "README.md"
)

# 내장 fallback exclude (rg/grep 양쪽 모두). .preflightignore 는 별도 추가.
# preflight 스크립트 자신(*.sh / *.ps1 / *.test.sh) + 테스트 픽스처 + deploy.yml 코드블록은
# 자기자신이 포함한 패턴 문자열로 self-detect 트리거가 발생하지 않도록 영구 제외.
# (예: 스크립트 내 EXCLUDE_GLOBS 목록, 테스트 fixture, deploy.yml env 블록)
EXCLUDE_GLOBS=(
  "*/node_modules/*"
  "*/.git/*"
  "*/.terraform/*"
  "*/dist/*"
  "*/build/*"
  "*/.next/*"
  "*/.expo/*"
  "*/coverage/*"
  "*/__fixtures__/*"
  "*/__tests__/*"
  # preflight 스크립트 자신 — self-detect 영구 차단.
  "*/preflight-placeholders.sh"
  "*/preflight-placeholders.ps1"
  "*/preflight-placeholders.test.sh"
  # CI 워크플로우 env 블록에 패턴이 명시되는 경우 self-detect 차단.
  "*/.github/workflows/deploy.yml"
  "*/.github/workflows/test-gate.yml"
  # ignore 설정 파일 자체
  "*/.preflightignore"
  "*/CHANGELOG.md"
  # 빌드 스크립트 / CI 설정 파일은 placeholder 가 예시로 포함될 수 있음.
  "*/build-and-upload.sh"
  "*/post-deploy-smoke.sh"
)

ROOT="${1:-}"
if [ -z "$ROOT" ]; then
  script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  # scripts/ -> 6. CI/ -> ICONIA root
  ROOT=$(cd "$script_dir/../.." && pwd)
fi

if [ ! -d "$ROOT" ]; then
  echo "ERR: repo root 디렉토리 없음: $ROOT" >&2
  exit 2
fi

# .preflightignore 로드 — gitignore 형식. 6. CI/.preflightignore 가 정본.
# 비주석/비공백 라인만 EXCLUDE_GLOBS 에 합산.
PREFLIGHTIGNORE="$ROOT/6. CI/.preflightignore"
if [ -f "$PREFLIGHTIGNORE" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    # trim
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -z "$line" ] && continue
    case "$line" in
      \#*) continue ;;
    esac
    EXCLUDE_GLOBS+=("$line")
  done < "$PREFLIGHTIGNORE"
fi

# 검사 대상 디렉토리 (1~6 만 가정. 다른 항목은 스킵).
TARGETS=(
  "1. HW"
  "2. SERVER"
  "3. AI"
  "4. APP"
  "5. ADMIN"
  "6. CI"
)

# grep 명령 구성. ripgrep 가 PATH 에 실제 바이너리로 있으면 rg, 아니면 GNU grep.
# (shell 함수로 wrapping 된 rg 는 본 스크립트 컨텍스트에서 보이지 않음 - 의도된 동작.)
USE_RG=0
if command -v rg >/dev/null 2>&1 && [ -x "$(command -v rg)" ]; then
  USE_RG=1
  RG_BASE=(rg --no-heading --line-number --hidden)
  for g in "${EXCLUDE_GLOBS[@]}"; do
    # rg --glob 은 gitignore 스타일이지만 leading '*/' 패턴은 그대로 처리. '**/...' 도 그대로 가능.
    RG_BASE+=(--glob "!$g")
  done
else
  GREP_BASE=(grep -RHn --binary-files=without-match)
  for g in "${EXCLUDE_GLOBS[@]}"; do
    name=$(basename "$g")
    case "$name" in
      *\**) continue ;;            # 와일드카드 잔존 -> skip
      *.*)  GREP_BASE+=(--exclude "$name") ;;   # 파일명 (확장자 포함)
      *)    GREP_BASE+=(--exclude-dir "$name") ;;
    esac
  done
  # 자주 쓰는 디렉토리는 명시적으로 한 번 더 (basename 추출 실패 대비).
  for d in node_modules .git .terraform dist build .next .expo coverage docs out __tests__ __fixtures__; do
    GREP_BASE+=(--exclude-dir "$d")
  done
fi

# 단일 패턴 실행 — fixed-string 인지 regex 인지에 따라 옵션 분기.
run_search() {
  local pat="$1" mode="$2" dir="$3"
  if [ "$USE_RG" -eq 1 ]; then
    if [ "$mode" = "F" ]; then
      "${RG_BASE[@]}" --fixed-strings -- "$pat" "$dir" 2>/dev/null || true
    else
      "${RG_BASE[@]}" -- "$pat" "$dir" 2>/dev/null || true
    fi
  else
    if [ "$mode" = "F" ]; then
      "${GREP_BASE[@]}" -F -- "$pat" "$dir" 2>/dev/null || true
    else
      "${GREP_BASE[@]}" -E -- "$pat" "$dir" 2>/dev/null || true
    fi
  fi
}

# 약관/사업자정보 강제 검사 — docs/README ignore 와 무관하게 LEGAL_SUBPATHS 직접 스캔.
# node_modules / .git / build 산출물만 회피하고, 약관 본문/legal config 의 placeholder
# 잔존을 잡는다. fixed-string 만 사용 (legal placeholder 는 모두 fixed).
run_legal_search() {
  local pat="$1" path="$2"
  if [ -d "$path" ]; then
    grep -RHnF --binary-files=without-match \
      --exclude-dir=node_modules --exclude-dir=.git --exclude-dir=.terraform \
      --exclude-dir=.next --exclude-dir=.expo --exclude-dir=build --exclude-dir=dist \
      --exclude-dir=out --exclude-dir=coverage \
      -- "$pat" "$path" 2>/dev/null || true
  elif [ -f "$path" ]; then
    grep -HnF --binary-files=without-match -- "$pat" "$path" 2>/dev/null || true
  fi
}

FOUND=0
TOTAL_HITS=0

for target in "${TARGETS[@]}"; do
  dir="$ROOT/$target"
  [ -d "$dir" ] || continue
  for spec in "${PATTERNS_SPEC[@]}"; do
    pat="${spec%|*}"
    mode="${spec#*|}"
    hits=$(run_search "$pat" "$mode" "$dir")
    if [ -n "$hits" ]; then
      FOUND=1
      n=$(printf '%s\n' "$hits" | grep -c '^' || true)
      TOTAL_HITS=$((TOTAL_HITS + n))
      printf '\n[FAIL] %s 의 [%s] (%s) %d 건:\n' "$target" "$pat" "$mode" "$n"
      printf '%s\n' "$hits"
    fi
  done
done

# --- 약관 / 사업자정보 강제 검사 (LEGAL_PATTERNS_SPEC × LEGAL_SUBPATHS) -------
# 본 패스는 docs/README ignore 와 별개로 약관 본문/legal config 만 직격 스캔한다.
# (주)숨코리아 사업자등록번호/통신판매업 신고번호 등 placeholder 가 prod 빌드로
# 새는 사고 차단.
#
# 2026-06-04 — LEGAL_WARN_ONLY=1 일 때 LEGAL 패스의 결과를 fail 이 아닌 warning 으로
# 다운그레이드한다. 운영팀이 실 사업자정보 미확정 단계에서 ADMIN/SERVER 코드만 먼저
# 배포해야 할 때 임시 사용 (예: 일반 코드 수정 hotfix). UI 는 isLegalEntityPublishable()
# fallback 으로 사업자정보 푸터를 가리므로 PIPA/전자상거래법 단기 위반 위험 최소.
# v1.0.0 정식 출시 태그 전에는 반드시 실 값으로 채우고 본 플래그를 제거해야 함.
LEGAL_FOUND=0
LEGAL_HITS=0
for target in "${TARGETS[@]}"; do
  base="$ROOT/$target"
  [ -d "$base" ] || continue
  for sub in "${LEGAL_SUBPATHS[@]}"; do
    path="$base/$sub"
    [ -e "$path" ] || continue
    for spec in "${LEGAL_PATTERNS_SPEC[@]}"; do
      pat="${spec%|*}"
      mode="${spec#*|}"
      hits=$(run_legal_search "$pat" "$path")
      if [ -n "$hits" ]; then
        LEGAL_FOUND=1
        n=$(printf '%s\n' "$hits" | grep -c '^' || true)
        LEGAL_HITS=$((LEGAL_HITS + n))
        tag="FAIL/legal"
        [ "${LEGAL_WARN_ONLY:-0}" = "1" ] && tag="WARN/legal"
        printf '\n[%s] %s/%s 의 [%s] (%s) %d 건:\n' "$tag" "$target" "$sub" "$pat" "$mode" "$n"
        printf '%s\n' "$hits"
      fi
    done
  done
done

# LEGAL 결과를 종합. WARN_ONLY 모드에서는 LEGAL 만으로 FOUND/TOTAL_HITS 를 올리지 않는다.
if [ "$LEGAL_FOUND" -eq 1 ] && [ "${LEGAL_WARN_ONLY:-0}" != "1" ]; then
  FOUND=1
  TOTAL_HITS=$((TOTAL_HITS + LEGAL_HITS))
fi

if [ "$FOUND" -ne 0 ]; then
  printf '\n========================================================================\n'
  printf 'preflight FAIL: 총 %d 건 placeholder 발견. release 차단.\n' "$TOTAL_HITS"
  printf '약관/사업자정보 잔존이면 (주)숨코리아 운영팀 갱신 절차 — docs/legal/business-info.md 참조.\n'
  printf '========================================================================\n'
  exit 1
fi

if [ "$LEGAL_FOUND" -eq 1 ] && [ "${LEGAL_WARN_ONLY:-0}" = "1" ]; then
  printf '\n========================================================================\n'
  printf 'preflight WARN: 총 %d 건 약관/사업자정보 placeholder (LEGAL_WARN_ONLY=1 로 임시 통과).\n' "$LEGAL_HITS"
  printf 'v1.0.0 정식 출시 전 실 값 입력 + 본 플래그 제거 필수.\n'
  printf '========================================================================\n'
fi

printf 'preflight OK - %d 패턴 + %d 약관 패턴 검사 통과, placeholder 없음.\n' \
  "${#PATTERNS_SPEC[@]}" "${#LEGAL_PATTERNS_SPEC[@]}"
exit 0
