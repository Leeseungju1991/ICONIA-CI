# (주)숨코리아 정책 안내 사이트

> ICONIA 서비스의 이용약관·개인정보처리방침·AI 이용 안내·기기 연결·커머스·마케팅·위치정보·오픈소스 라이선스 등 사용자 고지용 정적 사이트.

## 구조

```
policy-site/
├── index.html              # SPA shell (모든 정책을 hash routing 으로 표시)
├── assets/
│   ├── style.css           # 회사 사이트 톤 (white + indigo accent, mobile-friendly)
│   └── app.js              # SPA router + markdown loader (marked.js CDN)
├── content/                # 정책 markdown 원본 (8 개)
│   ├── terms.md
│   ├── privacy.md
│   ├── ai-disclosure.md
│   ├── device.md
│   ├── commerce.md
│   ├── marketing.md
│   ├── location.md
│   └── open-source.md
├── deploy/                 # 배포 가이드
│   ├── s3-cloudfront.md    # AWS S3 + CloudFront (권장)
│   ├── netlify.toml        # Netlify (zero-config)
│   └── nginx.conf          # 자체 서버 (nginx)
└── README.md
```

## 로컬 미리보기

```bash
# Python 3
cd "6. CI/policy-site"
python -m http.server 8000

# 또는 Node
npx serve

# 브라우저: http://localhost:8000
```

## 정책 본문 갱신

`content/*.md` 파일을 편집하면 즉시 사이트에 반영됩니다 (브라우저 새로고침).

정책 본문 정본은 `6. CI/docs/legal/*.md` — 본 사이트의 `content/*.md` 는 정본의 복사본입니다. 정본 갱신 시 동기화:

```bash
cd "6. CI"
cp docs/legal/privacy-policy.md       policy-site/content/privacy.md
cp docs/legal/terms-of-service.md     policy-site/content/terms.md
cp docs/legal/ai-disclosure-policy.md policy-site/content/ai-disclosure.md
cp docs/legal/device-connection-policy.md policy-site/content/device.md
cp docs/legal/commerce-display-policy.md  policy-site/content/commerce.md
cp docs/legal/open-source-notice.md   policy-site/content/open-source.md
cp docs/legal/location-policy.md      policy-site/content/location.md
cp docs/legal/marketing-consent.md    policy-site/content/marketing.md
```

또는 빌드 단계에서 자동 sync (CI workflow 추가 가능).

## 회사 정보

회사 정보 (대표자·사업자등록번호·주소 등) 는 `index.html` 의 [회사 정보 / 문의] 섹션 + footer 에 박혀 있습니다.

사업자 등록 완료 후 다음 4개 위치 갱신:
1. `index.html` 의 `.info-list` 안 `(사업자 등록 완료 후 갱신)` 부분
2. `6. CI/docs/legal/business-info.md` (정본)
3. `5. ADMIN/lib/companyInfo.ts` (ADMIN 콘솔 footer)
4. 본 README.md 의 §회사 정보

## 배포

`deploy/` 폴더 참조:
- **AWS S3 + CloudFront** (권장) — `deploy/s3-cloudfront.md`
- **Netlify** (가장 빠름, 무료 tier) — `deploy/netlify.toml`
- **자체 nginx** — `deploy/nginx.conf`

도메인 후보 (사용자 결정):
- `policy.dollsoom.com`
- `legal.iconia.dev`
- `soomkorea.com/policy` (회사 사이트 일부)

## SEO

- meta description / og 태그 포함
- `<meta name="robots" content="index, follow">`
- 단점: SPA 라 hash routing → 검색엔진 색인 약함. 출시 후 정책별 정적 .html 분리 가능 (별도 작업).

## 접근성 (a11y)

- skip-link
- 시맨틱 마크업 (header / nav / main / article / footer)
- 모바일 nav `aria-expanded`
- 색 대비 WCAG AA

## 정책 갱신

정책 본문 변경 시 정본 (`6. CI/docs/legal/*.md`) → `content/*.md` 동기화 → 배포.
