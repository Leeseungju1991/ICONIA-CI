# Changelog — ICONIA CI (배포/환경)

이 문서의 형식은 [Keep a Changelog 1.1.0](https://keepachangelog.com/ko/1.1.0/) 을 따르며, 이 프로젝트는 [SemVer](https://semver.org/lang/ko/) 를 따른다.

## [Unreleased] — 2026-06-04

### Changed

- `scripts/preflight-placeholders.sh` — `LEGAL_WARN_ONLY=1` env 플래그 추가.
  설정 시 약관/사업자정보 placeholder 검사 결과를 fail 이 아닌 warning 으로
  다운그레이드한다. 일반 placeholder 검사 (TOKEN / CHANGEME / INSERT_*_HERE
  등) 는 그대로 fail. 운영팀 사업자정보 미확정 단계에서 ADMIN/SERVER 코드
  hotfix 만 먼저 배포해야 할 때 임시 사용.
- `.github/workflows/deploy.yml` — preflight job 의 placeholder 검사 step 에
  `env.LEGAL_WARN_ONLY: '1'` 추가. v1.0.0 정식 출시 태그 전에는 실 사업자정보
  입력 + 본 env 제거 필수 (출시 정합 정책상 강제).

## [Unreleased] — 2026-05-27

### Added
- 신규 ENV 4종 운영 정책 표준화: `SILENCE_COMMAND_ENABLED`, `DEVICE_SILENCE_THRESHOLD_MIN`, `S3_KMS_KEY_ID`, `REDIS_URL` (production 은 `rediss://` 강제). 활성화 순서·롤백은 루트 `docs/ops-runbook-phase2.md` 참조.
