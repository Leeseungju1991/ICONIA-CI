#!/usr/bin/env bash
###############################################################################
# preflight-placeholders.test.sh
#
# preflight-placeholders.sh 단위 테스트.
# - clean tree 에서 exit 0.
# - 인위적 placeholder 주입 시 exit 1 + 패턴 식별 (fixed + regex).
# - .preflightignore 로 무시되는 경로는 검출 안 됨.
###############################################################################
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
preflight="$script_dir/preflight-placeholders.sh"

if [ ! -x "$preflight" ]; then
  chmod +x "$preflight"
fi

tmp=$(mktemp -d -t iconia-preflight-test.XXXX)
trap 'rm -rf "$tmp"' EXIT

# 6 폴더 mock + 6. CI/.preflightignore (실 운영처럼).
for n in "1. HW" "2. SERVER" "3. AI" "4. APP" "5. ADMIN" "6. CI"; do
  mkdir -p "$tmp/$n"
  printf '# %s\nclean\n' "$n" > "$tmp/$n/README.md"
done

# 테스트 환경의 6. CI/.preflightignore — README/docs 무시 + node_modules.
cat > "$tmp/6. CI/.preflightignore" <<'EOF'
# test fixture preflightignore
**/node_modules/**
**/docs/**
**/README.md
**/CHANGELOG.md
**/*.test.sh
**/build_profiles/dev.h
EOF

OUT=/tmp/preflight.out

# ---------- Test 1: clean tree -> exit 0 ----------
if ! "$preflight" "$tmp" >"$OUT" 2>&1; then
  echo "FAIL Test 1: clean tree 에서 exit != 0"
  cat "$OUT"
  exit 1
fi
echo "PASS Test 1: clean tree -> exit 0"

# ---------- Test 2: ICONIA_PROD_DOMAIN_PLACEHOLDER 주입 -> exit 1 ----------
echo "DOMAIN=ICONIA_PROD_DOMAIN_PLACEHOLDER" > "$tmp/2. SERVER/config.env"
set +e
"$preflight" "$tmp" >"$OUT" 2>&1
rc=$?
set -e
if [ "$rc" -ne 1 ]; then
  echo "FAIL Test 2: ICONIA_PROD_DOMAIN_PLACEHOLDER 주입 시 exit 1 기대, 실제 $rc"
  cat "$OUT"
  exit 1
fi
if ! grep -q "ICONIA_PROD_DOMAIN_PLACEHOLDER" "$OUT"; then
  echo "FAIL Test 2: 출력에 패턴 명시 없음"
  cat "$OUT"
  exit 1
fi
echo "PASS Test 2: ICONIA_PROD_DOMAIN_PLACEHOLDER -> exit 1 + 식별"
rm "$tmp/2. SERVER/config.env"

# ---------- Test 3: 여러 fixed-string placeholder 동시 -> 모두 식별 ----------
echo "API_KEY=PROD_API_KEY_PLACEHOLDER" > "$tmp/3. AI/keys.env"
echo "TOKEN=__FILL_ME__"               > "$tmp/4. APP/app.env"
echo "PAIR=PAIRING_TOKEN_PENDING"      > "$tmp/4. APP/pair.env"
set +e
"$preflight" "$tmp" >"$OUT" 2>&1
rc=$?
set -e
if [ "$rc" -ne 1 ]; then
  echo "FAIL Test 3: 다중 placeholder 시 exit 1 기대, 실제 $rc"
  cat "$OUT"
  exit 1
fi
for pat in PROD_API_KEY_PLACEHOLDER __FILL_ME__ PAIRING_TOKEN_PENDING; do
  if ! grep -q "$pat" "$OUT"; then
    echo "FAIL Test 3: 패턴 $pat 출력 누락"
    cat "$OUT"
    exit 1
  fi
done
echo "PASS Test 3: 다중 placeholder 모두 식별"
rm "$tmp/3. AI/keys.env" "$tmp/4. APP/app.env" "$tmp/4. APP/pair.env"

# ---------- Test 4: 추가 fixed-string 패턴 (your-domain-here / REPLACE_WITH_ / __SET_BY_EAS_SECRET__) ----------
echo "API=https://your-domain-here/v1"        > "$tmp/2. SERVER/cfg.env"
echo "KEY=REPLACE_WITH_TOKEN"                 > "$tmp/3. AI/keys.env"
echo "EAS=__SET_BY_EAS_SECRET__"              > "$tmp/4. APP/eas.env"
set +e
"$preflight" "$tmp" >"$OUT" 2>&1
rc=$?
set -e
if [ "$rc" -ne 1 ]; then
  echo "FAIL Test 4: 추가 패턴 주입 시 exit 1 기대, 실제 $rc"
  cat "$OUT"
  exit 1
fi
for pat in 'your-domain-here' 'REPLACE_WITH_' '__SET_BY_EAS_SECRET__'; do
  if ! grep -q "$pat" "$OUT"; then
    echo "FAIL Test 4: 패턴 $pat 출력 누락"
    cat "$OUT"
    exit 1
  fi
done
echo "PASS Test 4: 추가 fixed-string 패턴 (your-domain-here, REPLACE_WITH_, __SET_BY_EAS_SECRET__)"
rm "$tmp/2. SERVER/cfg.env" "$tmp/3. AI/keys.env" "$tmp/4. APP/eas.env"

# ---------- Test 5: regex 패턴 (TODO(prod) / XXXXXX / <replace here> / INSERT_X_HERE) ----------
echo "// TODO(prod): replace with secret"     > "$tmp/2. SERVER/todo.js"
echo "secret = AKIAXXXXXXXXXXXXXXXX"          > "$tmp/3. AI/aws.env"
echo '<replace api key here>'                  > "$tmp/4. APP/tpl.xml"
echo "URL=INSERT_BACKEND_URL_HERE"            > "$tmp/5. ADMIN/cfg.env"
set +e
"$preflight" "$tmp" >"$OUT" 2>&1
rc=$?
set -e
if [ "$rc" -ne 1 ]; then
  echo "FAIL Test 5: regex 패턴 주입 시 exit 1 기대, 실제 $rc"
  cat "$OUT"
  exit 1
fi
# 각 regex 패턴 표기가 출력에 등장하는지 (패턴 문자열 그대로 출력됨).
for tag in 'TODO' 'XXXXXX+' '<replace' 'INSERT_'; do
  if ! grep -q "$tag" "$OUT"; then
    echo "FAIL Test 5: regex 태그 $tag 식별 누락"
    cat "$OUT"
    exit 1
  fi
done
echo "PASS Test 5: regex 패턴 모두 식별"
# 5b: example.com 은 더 이상 패턴이 아니므로 (URL/email 모두) — release 차단 노이즈 방지.
echo "API_BASE=https://api.example.com/v1"     > "$tmp/5. ADMIN/apiurl.env"
echo "admin@example.com"                       > "$tmp/5. ADMIN/contact.txt"
rm "$tmp/2. SERVER/todo.js" "$tmp/3. AI/aws.env" "$tmp/4. APP/tpl.xml" "$tmp/5. ADMIN/cfg.env"
if ! "$preflight" "$tmp" >"$OUT" 2>&1; then
  echo "FAIL Test 5b: example.com (URL or email) 이 잘못 검출됨 — false-positive 방지 정책 위반"
  cat "$OUT"
  exit 1
fi
echo "PASS Test 5b: example.com (URL/email 모두) 무시 — false-positive 방지"
rm "$tmp/5. ADMIN/apiurl.env" "$tmp/5. ADMIN/contact.txt"

# ---------- Test 6: exclude 디렉토리(node_modules) 안의 placeholder 는 무시 ----------
mkdir -p "$tmp/4. APP/node_modules/foo"
echo "CHANGE_ME=yes" > "$tmp/4. APP/node_modules/foo/index.js"
if ! "$preflight" "$tmp" >"$OUT" 2>&1; then
  echo "FAIL Test 6: node_modules 안의 placeholder 가 검출됨 (exclude 깨짐)"
  cat "$OUT"
  exit 1
fi
echo "PASS Test 6: node_modules exclude 적용"
rm -rf "$tmp/4. APP/node_modules"

# ---------- Test 7: .preflightignore 의 **/docs/** 가 적용 ----------
mkdir -p "$tmp/2. SERVER/docs"
echo "예시: CHANGE_ME" > "$tmp/2. SERVER/docs/example.md"
if ! "$preflight" "$tmp" >"$OUT" 2>&1; then
  echo "FAIL Test 7: docs/ 안 placeholder 가 검출됨 (.preflightignore 미적용)"
  cat "$OUT"
  exit 1
fi
echo "PASS Test 7: .preflightignore **/docs/** 적용"
rm -rf "$tmp/2. SERVER/docs"

# ---------- Test 8: build_profiles/dev.h 는 무시되지만 prod.h 는 검출 ----------
mkdir -p "$tmp/1. HW/build_profiles"
echo "#define API_KEY \"CHANGE_ME\"" > "$tmp/1. HW/build_profiles/dev.h"
# dev.h 만 있을 때 통과해야 함.
if ! "$preflight" "$tmp" >"$OUT" 2>&1; then
  echo "FAIL Test 8a: build_profiles/dev.h 의 CHANGE_ME 가 검출됨 (.preflightignore 미적용)"
  cat "$OUT"
  exit 1
fi
echo "PASS Test 8a: build_profiles/dev.h 의 placeholder 는 무시"
# 동일 디렉토리의 prod.h 는 검출되어야.
echo "#define API_KEY \"CHANGE_ME\"" > "$tmp/1. HW/build_profiles/prod.h"
set +e
"$preflight" "$tmp" >"$OUT" 2>&1
rc=$?
set -e
if [ "$rc" -ne 1 ]; then
  echo "FAIL Test 8b: build_profiles/prod.h 의 CHANGE_ME 미검출 (rc=$rc)"
  cat "$OUT"
  exit 1
fi
echo "PASS Test 8b: build_profiles/prod.h 는 정상 검출"
rm -rf "$tmp/1. HW/build_profiles"

# ---------- Test 9: 약관/사업자정보 placeholder (docs/legal/) — docs/** ignore 우회 ----------
# (주)숨코리아 약관/사업자정보 정본 placeholder 가 docs/** ignore 와 무관하게 차단되어야 함.
mkdir -p "$tmp/2. SERVER/docs/legal"
cat > "$tmp/2. SERVER/docs/legal/privacy_policy.md" <<'EOF'
# 개인정보처리방침
회사명: __TBD__
사업자등록번호: XXX-XX-XXXXX
대표자: __PLACEHOLDER__
EOF
set +e
"$preflight" "$tmp" >"$OUT" 2>&1
rc=$?
set -e
if [ "$rc" -ne 1 ]; then
  echo "FAIL Test 9: docs/legal/ 의 약관 placeholder 가 검출되지 않음 (rc=$rc)"
  cat "$OUT"
  exit 1
fi
for pat in '__TBD__' 'XXX-XX-XXXXX' '__PLACEHOLDER__'; do
  if ! grep -q "$pat" "$OUT"; then
    echo "FAIL Test 9: 약관 패턴 $pat 출력 누락"
    cat "$OUT"
    exit 1
  fi
done
if ! grep -q '\[FAIL/legal\]' "$OUT"; then
  echo "FAIL Test 9: legal 강제 검사 마커 [FAIL/legal] 누락"
  cat "$OUT"
  exit 1
fi
echo "PASS Test 9: docs/legal/ 약관 placeholder (__TBD__ / XXX-XX-XXXXX / __PLACEHOLDER__) 검출"
rm -rf "$tmp/2. SERVER/docs/legal"

# ---------- Test 10: src/config/legal.ts 사업자정보 placeholder ----------
mkdir -p "$tmp/4. APP/src/config"
cat > "$tmp/4. APP/src/config/legal.ts" <<'EOF'
export const COMPANY_LEGAL_NAME_EN = 'Soom Korea Inc. (placeholder)';
export const COMPANY_BUSINESS_NUMBER = 'XXX-XX-XXXXX';
EOF
set +e
"$preflight" "$tmp" >"$OUT" 2>&1
rc=$?
set -e
if [ "$rc" -ne 1 ]; then
  echo "FAIL Test 10: src/config/legal.ts 의 placeholder 가 검출되지 않음 (rc=$rc)"
  cat "$OUT"
  exit 1
fi
for pat in 'Soom Korea Inc. (placeholder)' 'XXX-XX-XXXXX'; do
  if ! grep -qF "$pat" "$OUT"; then
    echo "FAIL Test 10: 패턴 $pat 출력 누락"
    cat "$OUT"
    exit 1
  fi
done
echo "PASS Test 10: src/config/legal.ts (Soom Korea Inc. (placeholder) / XXX-XX-XXXXX) 검출"
rm -rf "$tmp/4. APP/src/config"

# ---------- Test 11: clean legal 본문은 통과 (실제 (주)숨코리아 약관 형식 모방) ----------
mkdir -p "$tmp/2. SERVER/docs/legal"
cat > "$tmp/2. SERVER/docs/legal/privacy_policy.md" <<'EOF'
# 개인정보처리방침
회사명: (주)숨코리아
사업자등록번호: 123-45-67890
통신판매업 신고번호: 제2026-서울강남-12345호
대표자: 홍길동
EOF
mkdir -p "$tmp/4. APP/src/config"
cat > "$tmp/4. APP/src/config/legal.ts" <<'EOF'
export const COMPANY_LEGAL_NAME_KO = '주식회사 숨코리아';
export const COMPANY_TRADE_NAME = '(주)숨코리아';
export const COMPANY_BUSINESS_NUMBER = '123-45-67890';
EOF
if ! "$preflight" "$tmp" >"$OUT" 2>&1; then
  echo "FAIL Test 11: clean 약관/legal 본문이 false positive 로 차단됨"
  cat "$OUT"
  exit 1
fi
echo "PASS Test 11: clean (주)숨코리아 약관 본문 통과"
rm -rf "$tmp/2. SERVER/docs/legal" "$tmp/4. APP/src/config"

echo ""
echo "All preflight-placeholders.sh tests passed."
