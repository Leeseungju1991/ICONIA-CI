#!/usr/bin/env bash
###############################################################################
# check-soul-catalog-sync.test.sh
#
# check-soul-catalog-sync.js 단위 테스트.
# - 실제 server/AI catalog 가 동치 → exit 0.
# - 인위적 mismatch 주입 시 exit 1 + 차이 출력.
###############################################################################
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
checker="$script_dir/check-soul-catalog-sync.js"

if [ ! -f "$checker" ]; then
  echo "FAIL: checker 스크립트 없음: $checker"
  exit 1
fi

tmp=$(mktemp -d -t iconia-catalog-sync-test.XXXX)
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/2. SERVER/src/utils" "$tmp/3. AI/src"

OUT="/tmp/catalog-sync.out"

write_server() {
  local ids="$1"
  cat > "$tmp/2. SERVER/src/utils/soulCatalog.js" <<EOF
export const SOUL_CATALOG_V1_IDS = Object.freeze([
$ids
]);
EOF
}

write_ai() {
  local ids="$1"
  cat > "$tmp/3. AI/src/catalog.js" <<EOF
export const CATALOG_V1_IDS = Object.freeze([
$ids
]);
EOF
}

CANON_IDS='  "ehlard",
  "noah",
  "sion",
  "cillian",
  "erin",
  "ailon",
  "aiden",
  "paeron",
  "darian",
  "ian",
  "kaen",
  "draven",'

# ---------- Test 1: 동치 → exit 0 ----------
write_server "$CANON_IDS"
write_ai "$CANON_IDS"
if ! node "$checker" --root "$tmp" >"$OUT" 2>&1; then
  echo "FAIL Test 1: 동치 카탈로그에서 exit != 0"
  cat "$OUT"
  exit 1
fi
if ! grep -q "12 종 동치" "$OUT"; then
  echo "FAIL Test 1: 정상 출력 누락"
  cat "$OUT"
  exit 1
fi
echo "PASS Test 1: 동치 카탈로그 → exit 0"

# ---------- Test 2: 순서 다름 → 여전히 exit 0 (set-equal) ----------
write_server "$CANON_IDS"
write_ai '  "draven",
  "kaen",
  "ian",
  "darian",
  "paeron",
  "aiden",
  "ailon",
  "erin",
  "cillian",
  "sion",
  "noah",
  "ehlard",'
if ! node "$checker" --root "$tmp" >"$OUT" 2>&1; then
  echo "FAIL Test 2: 순서만 다른 카탈로그에서 exit != 0"
  cat "$OUT"
  exit 1
fi
echo "PASS Test 2: 순서 무관 set-equal 동작"

# ---------- Test 3: AI 에 ID 1개 누락 → exit 1 + 차이 표기 ----------
write_server "$CANON_IDS"
write_ai '  "ehlard",
  "noah",
  "sion",
  "cillian",
  "erin",
  "ailon",
  "aiden",
  "paeron",
  "darian",
  "ian",
  "kaen",'
set +e
node "$checker" --root "$tmp" >"$OUT" 2>&1
rc=$?
set -e
if [ "$rc" -ne 1 ]; then
  echo "FAIL Test 3: 누락된 AI 카탈로그에서 exit 1 기대, 실제 $rc"
  cat "$OUT"
  exit 1
fi
if ! grep -q "draven" "$OUT"; then
  echo "FAIL Test 3: 출력에 누락 ID 'draven' 명시 없음"
  cat "$OUT"
  exit 1
fi
echo "PASS Test 3: AI 누락 ID 'draven' 식별"

# ---------- Test 4: server 에만 추가된 ID → exit 1 + extra 표기 ----------
write_server '  "ehlard",
  "noah",
  "sion",
  "cillian",
  "erin",
  "ailon",
  "aiden",
  "paeron",
  "darian",
  "ian",
  "kaen",
  "draven",
  "newcomer",'
write_ai "$CANON_IDS"
set +e
node "$checker" --root "$tmp" >"$OUT" 2>&1
rc=$?
set -e
if [ "$rc" -ne 1 ]; then
  echo "FAIL Test 4: server 만 확장한 경우 exit 1 기대, 실제 $rc"
  cat "$OUT"
  exit 1
fi
if ! grep -q "newcomer" "$OUT"; then
  echo "FAIL Test 4: 출력에 server-only ID 'newcomer' 명시 없음"
  cat "$OUT"
  exit 1
fi
echo "PASS Test 4: server-only ID 'newcomer' 식별"

# ---------- Test 5: 중복 ID → 별도 FAIL ----------
write_server '  "ehlard",
  "noah",
  "sion",
  "cillian",
  "erin",
  "ailon",
  "aiden",
  "paeron",
  "darian",
  "ian",
  "kaen",
  "draven",
  "noah",'
write_ai "$CANON_IDS"
set +e
node "$checker" --root "$tmp" >"$OUT" 2>&1
rc=$?
set -e
if [ "$rc" -ne 1 ]; then
  echo "FAIL Test 5: server 중복 ID 시 exit 1 기대, 실제 $rc"
  cat "$OUT"
  exit 1
fi
if ! grep -q "중복" "$OUT"; then
  echo "FAIL Test 5: 출력에 '중복' 표기 없음"
  cat "$OUT"
  exit 1
fi
echo "PASS Test 5: 중복 ID 식별"

# ---------- Test 6: 파일 없음 → exit 2 ----------
rm "$tmp/3. AI/src/catalog.js"
set +e
node "$checker" --root "$tmp" >"$OUT" 2>&1
rc=$?
set -e
if [ "$rc" -ne 2 ]; then
  echo "FAIL Test 6: AI 카탈로그 없음 시 exit 2 기대, 실제 $rc"
  cat "$OUT"
  exit 1
fi
echo "PASS Test 6: 파일 없음 → exit 2"

# ---------- Test 7: 실제 repo 의 카탈로그 동기화 (라이브 sanity) ----------
real_root=$(cd "$script_dir/../.." && pwd)
if [ -f "$real_root/2. SERVER/src/utils/soulCatalog.js" ] && [ -f "$real_root/3. AI/src/catalog.js" ]; then
  if ! node "$checker" --root "$real_root" >"$OUT" 2>&1; then
    echo "FAIL Test 7: 실제 repo 카탈로그 동기화 실패"
    cat "$OUT"
    exit 1
  fi
  echo "PASS Test 7: 실제 ICONIA repo 카탈로그 동치 확인"
else
  echo "SKIP Test 7: 실제 repo 카탈로그 파일 미존재 (테스트 환경)"
fi

echo ""
echo "All check-soul-catalog-sync.js tests passed."
