# volta

AlDente를 대체하는 macOS 배터리 관리 메뉴바 앱. **macOS Tahoe 26 + Apple Silicon 전용.**

- 충전 상한, 강제 방전, 과열 보호, 하드웨어 배터리 비율, 라이브 전력 메트릭, 잠자기 연동, Apple Shortcuts.
- 2-프로세스: 앱(MenuBarExtra, 사용자 권한, 읽기·판단·UI) ↔ XPC ↔ root 헬퍼 데몬(SMC 쓰기·sleep 제어).
- 스택: Swift 6 / strict concurrency, Observation, Swift Concurrency(actor), SMAppService+XPC, App Intents.

## 구조

- `volta/` — 앱 타깃
- `voltaHelper/` — root 헬퍼 데몬(Command Line Tool)
- `Packages/VoltaCore/` — 공유 패키지(SMC 레이어·정책 엔진·XPC 프로토콜·모델)

## 빌드/서명 설정

코드서명 팀 ID는 repo에 두지 않는다(`Signing.xcconfig`는 `.gitignore`). 빌드 전에 예시 파일을
복사해 본인 팀 ID를 채운다:

```bash
cp Signing.xcconfig.example Signing.xcconfig   # 그 뒤 DEVELOPMENT_TEAM 값을 본인 팀 ID로 교체
```

## 상태

골격 작성 단계. **컴파일·실기 검증 전.** 진행 현황·검증 항목·남은 작업은 `docs/` 참조:

- `docs/implementation-status.md`
- `docs/user-test-checklist.md` (정밀 명령·안전/롤백 부록 포함)
- `docs/remaining-work.md`
- `docs/Xcode-환경설정-가이드.md`
- `docs/review-findings.md` (코드리뷰 지적·조치)
- `docs/verification-results.md` (Python 교차검증 35/35)
- `docs/aldente-ux-parity.md` (UX 대조)

## 라이선스

LICENSE 참조.
