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

# 내장 fallback exclude (rg/grep 양쪽 모두). .preflightignore 는 별도 추가.
EXCLUDE_GLOBS=(
  "*/node_modules/*"
  "*/.git/*"
  "*/.terraform/*"
  "*/dist/*"
  "*/build/*"
  "*/.next/*"
  "*/.expo/*"
  "*/preflight-placeholders.sh"
  "*/preflight-placeholders.ps1"
  "*/preflight-placeholders.test.sh"
  "*/.preflightignore"
  "*/CHANGELOG.md"
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

if [ "$FOUND" -ne 0 ]; then
  printf '\n========================================================================\n'
  printf 'preflight FAIL: 총 %d 건 placeholder 발견. release 차단.\n' "$TOTAL_HITS"
  printf '========================================================================\n'
  exit 1
fi

printf 'preflight OK - %d 패턴 검사 통과, placeholder 없음.\n' "${#PATTERNS_SPEC[@]}"
exit 0
