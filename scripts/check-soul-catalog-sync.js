#!/usr/bin/env node
/**
 * check-soul-catalog-sync.js
 *
 * Server `2. SERVER/src/utils/soulCatalog.js` 의 `SOUL_CATALOG_V1_IDS` 와
 * AI     `3. AI/src/catalog.js` 의 `CATALOG_V1_IDS` 가 lockstep 으로
 * 유지되는지 검증한다. 둘 중 하나만 24종으로 확장된 채 release 가 나가는 사고
 * (soul_catalog_id 가 server 화이트리스트는 통과했는데 AI 측 로드 실패 → 500) 차단.
 *
 * 동작:
 *   - 두 파일에서 array literal 정규식 추출 (의존 0 — node 표준 fs/path 만).
 *   - 순서 무관 set 동치 비교.
 *   - 다르면 missing/extra/duplicate 출력 + exit 1.
 *
 * 사용법:
 *   node 6.\ CI/scripts/check-soul-catalog-sync.js [--root <repo_root>]
 *
 * Exit codes:
 *   0  동기화 OK.
 *   1  mismatch — 차이 출력.
 *   2  사용법/입력 오류 (파일 없음/파싱 실패).
 */

const fs = require("node:fs");
const path = require("node:path");

function parseRoot(argv) {
  for (let i = 2; i < argv.length; i++) {
    if (argv[i] === "--root" && argv[i + 1]) return argv[i + 1];
  }
  // 기본: 본 스크립트 기준 ../..  (ICONIA root)
  return path.resolve(__dirname, "..", "..");
}

/**
 * JS 소스에서 `export const NAME = Object.freeze([ "a", "b", ... ])` 또는
 * `export const NAME = [ ... ]` 형식의 문자열 배열을 추출.
 * 주석/공백/trailing comma 허용. AST 안 쓰고 보수적 정규식으로 충분 (단일 라인 array
 * literal + 멀티라인 모두 처리). 실패 시 throw.
 */
function extractStringArray(source, name) {
  // `const NAME = ` 까지의 prefix 매칭, 그 뒤 첫 '[' 부터 매칭 괄호의 ']' 까지 슬라이스.
  // export 는 선택, Object.freeze( 도 선택.
  const head = new RegExp(
    `(?:export\\s+)?(?:const|let|var)\\s+${name}\\s*=\\s*(?:Object\\.freeze\\s*\\()?\\s*\\[`,
    "m"
  );
  const m = head.exec(source);
  if (!m) {
    throw new Error(`상수 ${name} 의 선언을 찾지 못함`);
  }
  const start = m.index + m[0].length; // '[' 다음 위치
  let depth = 1;
  let end = -1;
  for (let i = start; i < source.length; i++) {
    const c = source[i];
    if (c === "[") depth++;
    else if (c === "]") {
      depth--;
      if (depth === 0) {
        end = i;
        break;
      }
    }
  }
  if (end === -1) {
    throw new Error(`상수 ${name} 의 ']' 매칭 실패`);
  }
  const body = source.slice(start, end);
  // 문자열 리터럴만 추출 (single/double/backtick).
  const out = [];
  const re = /(['"`])((?:\\.|(?!\1).)*)\1/g;
  let mm;
  while ((mm = re.exec(body)) !== null) {
    out.push(mm[2]);
  }
  if (out.length === 0) {
    throw new Error(`상수 ${name} 의 배열에 문자열 리터럴이 없음`);
  }
  return out;
}

function setOf(arr) {
  return new Set(arr);
}

function findDuplicates(arr) {
  const seen = new Set();
  const dups = [];
  for (const v of arr) {
    if (seen.has(v)) dups.push(v);
    seen.add(v);
  }
  return dups;
}

function main() {
  const root = parseRoot(process.argv);
  const serverPath = path.join(root, "2. SERVER", "src", "utils", "soulCatalog.js");
  const aiPath = path.join(root, "3. AI", "src", "catalog.js");

  for (const [label, p] of [["server", serverPath], ["ai", aiPath]]) {
    if (!fs.existsSync(p)) {
      console.error(`ERR: ${label} catalog 파일 없음: ${p}`);
      process.exit(2);
    }
  }

  let serverIds, aiIds;
  try {
    const serverSrc = fs.readFileSync(serverPath, "utf8");
    serverIds = extractStringArray(serverSrc, "SOUL_CATALOG_V1_IDS");
  } catch (err) {
    console.error(`ERR: server SOUL_CATALOG_V1_IDS 파싱 실패 (${serverPath}): ${err.message}`);
    process.exit(2);
  }
  try {
    const aiSrc = fs.readFileSync(aiPath, "utf8");
    aiIds = extractStringArray(aiSrc, "CATALOG_V1_IDS");
  } catch (err) {
    console.error(`ERR: AI CATALOG_V1_IDS 파싱 실패 (${aiPath}): ${err.message}`);
    process.exit(2);
  }

  const serverSet = setOf(serverIds);
  const aiSet = setOf(aiIds);

  const onlyInServer = [...serverSet].filter((x) => !aiSet.has(x)).sort();
  const onlyInAi = [...aiSet].filter((x) => !serverSet.has(x)).sort();
  const serverDups = findDuplicates(serverIds);
  const aiDups = findDuplicates(aiIds);

  let fail = false;

  if (serverDups.length > 0) {
    console.error(`[FAIL] server SOUL_CATALOG_V1_IDS 중복: ${serverDups.join(", ")}`);
    fail = true;
  }
  if (aiDups.length > 0) {
    console.error(`[FAIL] AI CATALOG_V1_IDS 중복: ${aiDups.join(", ")}`);
    fail = true;
  }
  if (onlyInServer.length > 0) {
    console.error(`[FAIL] server 에만 있는 ID (${onlyInServer.length}): ${onlyInServer.join(", ")}`);
    fail = true;
  }
  if (onlyInAi.length > 0) {
    console.error(`[FAIL] AI 에만 있는 ID (${onlyInAi.length}): ${onlyInAi.join(", ")}`);
    fail = true;
  }
  if (serverIds.length !== aiIds.length) {
    console.error(`[FAIL] 개수 불일치: server=${serverIds.length}, ai=${aiIds.length}`);
    fail = true;
  }

  if (fail) {
    console.error("");
    console.error("========================================================================");
    console.error("soul_catalog sync FAIL — server/AI 카탈로그 lockstep 위반.");
    console.error("server: 2. SERVER/src/utils/soulCatalog.js :: SOUL_CATALOG_V1_IDS");
    console.error("ai:     3. AI/src/catalog.js               :: CATALOG_V1_IDS");
    console.error("========================================================================");
    process.exit(1);
  }

  console.log(
    `soul_catalog sync OK — ${serverIds.length} 종 동치 (set-equal). 순서 무관.`
  );
  process.exit(0);
}

main();
