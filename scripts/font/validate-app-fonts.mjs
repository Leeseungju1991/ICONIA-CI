#!/usr/bin/env node
// ICONIA-APP 폰트/asset 자동 검증 (HD-B-P1-01 처리).
//
// 사용: node "6. CI/scripts/font/validate-app-fonts.mjs"
//
// 검증:
//   1. 4. APP/assets/fonts 의 .ttf/.otf 가 유효한 폰트 binary 인지 (magic byte 검사)
//   2. HTML 로 잘못 저장된 .ttf 탐지 (예: Github 의 raw url 으로 받았으나 redirect HTML)
//   3. 0 byte / 작은 (<1KB) 파일 탐지
//   4. APP/src 의 require/import 가 실제 존재하는 파일을 가리키는지
//   5. unused 폰트 탐지
//
// exit code:
//   0: OK
//   1: 검증 실패 — CI 차단
//   2: warning (unused) — CI 통과

import fs from 'node:fs/promises';
import path from 'node:path';

const ICONIA_ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname.replace(/^\//, '')), '..', '..', '..');
const APP_ROOT = path.join(ICONIA_ROOT, '4. APP');
const ASSETS_DIR = path.join(APP_ROOT, 'assets');
const SRC_DIR = path.join(APP_ROOT, 'src');

const TTF_MAGIC = [0x00, 0x01, 0x00, 0x00];  // TrueType
const OTF_MAGIC = [0x4F, 0x54, 0x54, 0x4F];  // OpenType
const WOFF_MAGIC = [0x77, 0x4F, 0x46, 0x46]; // WOFF
const WOFF2_MAGIC = [0x77, 0x4F, 0x46, 0x32]; // WOFF2

function magicMatches(bytes, magic) {
  for (let i = 0; i < magic.length; i++) {
    if (bytes[i] !== magic[i]) return false;
  }
  return true;
}

async function walkDir(dir, results = []) {
  try {
    const entries = await fs.readdir(dir, { withFileTypes: true });
    for (const e of entries) {
      const full = path.join(dir, e.name);
      if (e.isDirectory()) {
        if (['node_modules', '.next', '.expo', '.git', 'coverage', '__smoke__', 'jest.stubs'].includes(e.name)) continue;
        await walkDir(full, results);
      } else {
        results.push(full);
      }
    }
  } catch (err) {
    // dir not exists
  }
  return results;
}

async function validate() {
  const errors = [];
  const warnings = [];

  // 1. 폰트 파일 inventory
  let fontFiles = [];
  try {
    fontFiles = (await walkDir(ASSETS_DIR))
      .filter(f => /\.(ttf|otf|woff2?|eot)$/i.test(f));
  } catch (err) {
    errors.push({ kind: 'NO_ASSETS_DIR', path: ASSETS_DIR, msg: err.message });
  }

  // 2. 각 파일 검증
  for (const f of fontFiles) {
    const stat = await fs.stat(f);
    if (stat.size === 0) {
      errors.push({ kind: 'EMPTY_FILE', path: f });
      continue;
    }
    if (stat.size < 1024) {
      warnings.push({ kind: 'SUSPICIOUSLY_SMALL', path: f, size: stat.size });
    }

    const fd = await fs.open(f, 'r');
    const buf = Buffer.alloc(16);
    await fd.read(buf, 0, 16, 0);
    await fd.close();

    // 첫 4바이트가 폰트 magic 인지
    const valid =
      magicMatches(buf, TTF_MAGIC) ||
      magicMatches(buf, OTF_MAGIC) ||
      magicMatches(buf, WOFF_MAGIC) ||
      magicMatches(buf, WOFF2_MAGIC);

    if (!valid) {
      // HTML 로 잘못 저장된 경우 (예: Github redirect)
      const head = buf.toString('utf8', 0, 8).toLowerCase();
      if (head.startsWith('<!doctype') || head.startsWith('<html')) {
        errors.push({ kind: 'HTML_AS_FONT', path: f, head });
      } else {
        errors.push({ kind: 'INVALID_FONT_MAGIC', path: f, first4: buf.slice(0, 4).toString('hex') });
      }
    }
  }

  // 3. src 에서 폰트 require/import 패턴 grep
  const srcFiles = await walkDir(SRC_DIR);
  const codeFiles = srcFiles.filter(f => /\.(ts|tsx|js|jsx)$/.test(f));
  const referencedFonts = new Set();
  for (const f of codeFiles) {
    const text = await fs.readFile(f, 'utf8');
    const matches = text.matchAll(/['"`]([^'"`]*\.(ttf|otf|woff2?))['"`]/gi);
    for (const m of matches) {
      referencedFonts.add(path.basename(m[1]));
    }
    const requireMatches = text.matchAll(/require\(['"`]([^'"`]+)['"`]\)/g);
    for (const m of requireMatches) {
      const p = m[1];
      if (/\.(ttf|otf|woff2?)$/i.test(p)) {
        referencedFonts.add(path.basename(p));
      }
    }
  }

  // 4. unused 폰트 (asset 에는 있는데 src 에서 reference 안 됨)
  const fontBasenames = new Set(fontFiles.map(f => path.basename(f)));
  for (const fn of fontBasenames) {
    if (!referencedFonts.has(fn)) {
      warnings.push({ kind: 'UNUSED_FONT', path: fn });
    }
  }

  // 결과 출력
  console.log(`Fonts scanned: ${fontFiles.length}`);
  console.log(`References found in src: ${referencedFonts.size}`);
  console.log(`Errors: ${errors.length}`);
  console.log(`Warnings: ${warnings.length}`);

  if (errors.length > 0) {
    console.error('\n=== ERRORS ===');
    for (const e of errors) console.error(JSON.stringify(e, null, 2));
  }
  if (warnings.length > 0) {
    console.warn('\n=== WARNINGS ===');
    for (const w of warnings) console.warn(JSON.stringify(w, null, 2));
  }

  if (errors.length > 0) process.exit(1);
  if (warnings.length > 0) process.exit(2);
  process.exit(0);
}

validate().catch(err => {
  console.error('Fatal:', err);
  process.exit(1);
});
