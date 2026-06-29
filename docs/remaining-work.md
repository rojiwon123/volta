# 남은 작업 / 다음 단계

타깃 연결(섹션 A)은 **완료**됐다. 남은 건 **실기 검증 후 확정값 반영**(섹션 B)과 **기능 보강**(섹션 C).

## A. Xcode 타깃 연결 — ✅ 완료 (pbxproj에 반영됨)

`xcodebuild -list` 기준 타깃 `volta`/`voltaHelper`/패키지 `VoltaCore`(@ local) 모두 존재하고,
앱·헬퍼 둘 다 `BUILD SUCCEEDED`. 빌드 산출물 `volta.app` 검증:
- ✅ `VoltaCore` 로컬 패키지 연결(resolved @ local), 앱·헬퍼 모두 링크.
- ✅ `voltaHelper` Command Line Tool 타깃 + 소스(main/HelperListener/HelperService/SleepWatcher) 멤버십.
- ✅ 헬퍼 plist·바이너리 앱 번들 동봉: `Contents/Library/LaunchDaemons/com.rojiwon.volta.helper.plist`,
  `Contents/MacOS/voltaHelper`.
- ✅ 코드서명: 앱·헬퍼 동일 팀(`TeamIdentifier=<DEVELOPMENT_TEAM>`), Automatically manage signing.
- (App Intents는 자동 추출 — 빌드 후 단축어 앱 노출만 실기 확인.)

## B. 실기 검증 후 코드에 반영할 확정값

`user-test-checklist.md`에서 얻은 값으로 다음 자리표시자를 교체:

- `SMCKeys.batteryCharge` (현재 임시 `BUIC`) → 실제 충전% 키.
- `SMCKeys.chargeInhibit`/`adapterControl` FourCC 및 매직값 확정(CHTE/CHIE 가정 검증).
- `SMARTBattery` 프로퍼티 키/온도 단위(0.01K 가정) 확정.
- `PowerMetrics` 부호 규약 확정 후 `isBatteryChargingByPowerSign` 등 보정.
- `SMCKit`의 selector/cmd 인덱스, `SMCParamStruct` 레이아웃 실검증.

확정된 값:
- ✅ `HelperConstants.developmentTeamID = "<DEVELOPMENT_TEAM>"` — 빌드 산출물 서명의 리프 인증서
  `subject.OU`(=TeamIdentifier)로 확인. (이전 `CJ576XA3C2`는 Apple Development 인증서 CN의
  개인 식별자일 뿐 OU 아님 → XPC fail-closed 거부 버그였음.)

## C. 기능 보강 (그다음)

- SMC 폴링을 `AsyncStream` 기반 이벤트로 전환(전원 연결/해제 알림 + 주기 폴링 혼합).
- ✅ `isClamshellLikely` 실제 판별 — `IOPMrootDomain["AppleClamshellState"]`로 덮개 닫힘 읽음
  (`SMARTBattery.readClamshellClosed()`). 키 부재 시 nil=알 수 없음(경고 미표시). 실기에서 덮개
  닫았을 때 true 뜨는지·강제 방전 경고가 맞게 나오는지 확인 필요.
- 헬퍼 비정상 종료/부팅 시 안전 복구(충전 기본 허용)와 watchdog.
- 메뉴바 텍스트에 % 직접 노출 옵션, 설정 창(Settings Scene) 분리.
- 로깅을 `os.Logger`로 통일, 진단 화면(`getDiagnostics`) UI.
- 온도/전력 그래프(히스토리), 알림(상한 도달/과열).
- 다국어(현재 한국어 하드코딩 → String Catalog).
- 단위/통합 테스트 확대, CI(macOS 러너)에서 `swift test` + `xcodebuild`.

## D. 정리용 메모

- 이 작업 환경의 파일시스템 제약(파일 삭제 불가)으로, 더 이상 쓰지 않는 파일을 저장소 내 `.trash/`로 옮겨 두었습니다(.gitignore 처리됨). **Finder에서 `volta/.trash/` 폴더를 삭제**해도 됩니다. 내용: 과거 테스트 파일, Phase1에서 VoltaCore로 승격된 `SMCService.swift`/`ChargePolicyEngine.swift` 사본.
- git 원격(origin = github.com/rojiwon123/volta)은 `LICENSE`만 있던 기존 main을 `--allow-unrelated-histories`로 흡수해, 로컬 main이 원격을 조상으로 포함합니다 → **강제 push 없이 일반 push 가능**.
