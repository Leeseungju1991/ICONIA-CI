# ICONIA 사업자 정보 정본 — (주)숨코리아

ICONIA 서비스의 사업자 정보 단일 정본. 본 문서는 (주)숨코리아 운영팀이 직접
갱신하며, 6 레포(`1. HW` / `2. SERVER` / `3. AI` / `4. APP` / `5. ADMIN` / `6. CI`)
의 약관 본문 · 처리방침 · UI · 알람 메타데이터가 모두 본 문서 값을 따라간다.

릴리스 직전에 본 문서의 사업자등록번호·대표자·통신판매업 신고번호 placeholder 가
하나라도 남아 있으면 `preflight-placeholders.sh` 가 prod 배포를 차단한다.
(상세 차단 패턴은 `scripts/preflight-placeholders.sh` 의 `LEGAL_PATTERNS_SPEC` 참조)

---

## 1. 회사 기본 정보 (PIPA §30 ② / 전자상거래법 §10)

| 항목 | 값 | 상태 |
|---|---|---|
| 회사명 (국문) | 주식회사 숨코리아 | 확정 |
| 회사명 (영문) | SOOM Korea Inc. | 확정 |
| 상호 (브랜드) | (주)숨코리아 | 확정 |
| 서비스명 | ICONIA | 확정 |
| 대표자 | `__TBD__` | 운영팀 갱신 대상 |
| 사업자등록번호 | 130-86-41024 | 확정 |
| 통신판매업 신고번호 | `__TBD__` | 운영팀 갱신 대상 (결제 도입 시 신고) |
| 본사 소재지 | 서울특별시 마포구 와우산로 94 (04066), 홍익대학교 홍문관 B211호 | 확정 |
| 고객센터 전화 | 02-2038-2935 | 확정 |
| 대표 이메일 | web@soomkorea.com | 확정 |
| 도메인 (운영) | dollsoom.com | 확정 |

> 위 placeholder 가 남아있는 동안은 UI 가 "사업자 정보는 정식 출시 시 공지" 로
> fallback 표시한다 (`4. APP` 의 `src/config/legal.ts` 의 `isLegalEntityPublishable()`).

## 2. 개인정보 보호 책임자 (DPO) — PIPA §31

| 항목 | 값 | 상태 |
|---|---|---|
| 책임자 성명 | 이승주 | 확정 |
| 직책 | `__TBD__` | 운영팀 갱신 대상 |
| 연락처 (이메일) | web@soomkorea.com | 확정 |
| 연락처 (전화) | `__TBD__` | 운영팀 갱신 대상 |
| 신고/이의신청 채널 | web@soomkorea.com | 확정 |

## 3. 인증 / 신고 (HW 출시 게이트 — `1. HW` 참조)

| 인증 | 대상 | 상태 |
|---|---|---|
| KC 인증 (전파법 §58-2) | ICONIA 디바이스 (BLE/Wi-Fi 송수신) | `__TBD__` |
| FCC Part 15 (미국 진출 시) | ICONIA 디바이스 | `__TBD__` |
| RoHS / REACH | ICONIA 디바이스 자재 | `__TBD__` |
| 안전확인신고 (어린이제품 안전특별법) | 14세 미만 대상 시 — 본 서비스는 만 18세 이상 | 해당 없음 (재검토) |

상세 로드맵은 `1. HW/docs/safety-certification-roadmap.md`.

## 4. 운영팀 갱신 절차 (production 출시 직전 1회)

본 문서의 placeholder 가 prod 빌드에 잔존하면 `release-preflight` 워크플로우가
release 를 차단한다. 출시 직전 다음 순서로 갱신한다.

1. **본 문서 (`6. CI/docs/legal/business-info.md`) 갱신**
   - 위 표의 `상태=운영팀 갱신 대상` 셀을 실 값으로 치환.
   - 대표자 / 사업자등록번호 / 통신판매업 신고번호 / 본사 소재지 / 고객센터 / DPO 성명·전화.
2. **APP 사업자정보 코드 갱신 (`4. APP/src/config/legal.ts`)**
   - `COMPANY_REPRESENTATIVE`, `COMPANY_BUSINESS_NUMBER`, `COMPANY_MAIL_ORDER_NUMBER`,
     `COMPANY_ADDRESS_KO`, `COMPANY_PHONE`, `DPO_NAME` 의 placeholder 를 실 값으로 치환.
   - `isLegalEntityPublishable()` 가 `true` 를 반환해야 UI 가 사업자정보 푸터를 정상 노출.
3. **SERVER 처리방침 정본 갱신 (`2. SERVER/docs/legal/privacy_policy.md`)**
   - "1. 사업자 정보" 표의 법무 갱신 토큰을 실 값으로 치환.
   - 시행일도 함께 확정.
4. **HW 안전인증 메타 갱신 (`1. HW/docs/safety-certification-roadmap.md`)**
   - 제조사: (주)숨코리아 / 전화 / 주소 — 실 값으로.
   - KC / FCC 인증번호 확정 시 본 표에도 반영.
5. **preflight 로컬 검증**
   ```bash
   scripts/preflight-placeholders.sh  # 6 레포 root 에서
   ```
   `preflight OK` 가 나와야 release 진행.
6. **release tag 푸시**
   ```bash
   git tag v1.0.0 && git push origin v1.0.0
   ```
   `release-preflight` 가 통과해야 `deploy` 가 시작된다.

## 5. 갱신 시 함께 검토할 외부 노출 위치

| 위치 | 확인 | 비고 |
|---|---|---|
| `4. APP/src/copy/terms/ko/*.ts` | 약관 본문의 "(주)숨코리아" 표기 일관성 | 본문은 placeholder 가 아님 — 회사명만 갱신 |
| `4. APP/src/config/legal.ts` | 위 2번 항목 | UI fallback 헬퍼 정상 동작 확인 |
| `2. SERVER/docs/legal/privacy_policy.md` | 위 3번 항목 | 시행일 확정 |
| `2. SERVER/docs/legal/dpa_vendor_checklist.md` | 외주 처리자 계약 회사명 | (주)숨코리아 |
| `1. HW/docs/safety-certification-roadmap.md` | 제조사 / 인증번호 | KC / FCC |
| Apple App Store / Google Play 스토어 리스팅 | "Seller" 회사명 / 사업자정보 | 별도 트랙 |
| WooCommerce (dollsoom.com) 약관/연락처 | 본 정본과 동기화 | 별도 트랙 |
| Terraform `default_tags` (`6. CI/terraform/main.tf`) | `owner = "soomkorea"` | 인프라 비용 책임자 식별용 |

## 6. 변경 이력 (선택)

| 일자 | 항목 | 변경자 |
|---|---|---|
| 2026-05-26 | 정본 신설 (placeholder + 갱신 절차) | DevOps |
