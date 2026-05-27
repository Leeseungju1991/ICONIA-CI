# Changelog — ICONIA CI (배포/환경)

이 문서의 형식은 [Keep a Changelog 1.1.0](https://keepachangelog.com/ko/1.1.0/) 을 따르며, 이 프로젝트는 [SemVer](https://semver.org/lang/ko/) 를 따른다.

## [Unreleased] — 2026-05-27

### Added
- 신규 ENV 4종 운영 정책 표준화: `SILENCE_COMMAND_ENABLED`, `DEVICE_SILENCE_THRESHOLD_MIN`, `S3_KMS_KEY_ID`, `REDIS_URL` (production 은 `rediss://` 강제). 활성화 순서·롤백은 루트 `docs/ops-runbook-phase2.md` 참조.
