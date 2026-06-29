# volta 구현 현황 (자율 작업 결과)

작성: 2026-06-09 (자율 모드). 이 환경에는 **Xcode/Swift 툴체인이 없어 컴파일·실행 검증은 불가**합니다. 아래 "검증 필요" 표기는 모두 실기(맥)에서 확인해야 합니다. **어떤 것도 "동작 확정"이 아닙니다.**

## 1. 한눈에 보기

3개 모듈로 구성된 코드 골격을 모두 작성했습니다. Xcode에서 **타깃 2개(헬퍼·패키지)를 연결**하고 빌드하면 되는 상태를 목표로 했습니다(연결 작업은 `remaining-work.md`).

```
volta/                         # 저장소 루트 (Xcode 프로젝트)
├─ volta.xcodeproj             # 빌드 설정 적용됨(Swift6/strict concurrency/macOS26/arm64/LSUIElement/sandbox off)
├─ volta/                      # ① 앱 타깃 (MenuBarExtra, 사용자 권한)
│  ├─ voltaApp.swift           #   진입점(MenuBarExtra)
│  ├─ ContentView.swift        #   메뉴 팝오버 UI(상한 슬라이더/토글/상태)
│  ├─ BatteryMonitor.swift     #   @Observable 중심 모델: 폴링·정책·헬퍼 위임
│  ├─ Views/                   #   PowerFlowView, HelperStatusView
│  ├─ Helper/HelperClient.swift#   SMAppService 등록 + XPC 클라이언트
│  ├─ Intents/VoltaShortcuts.swift # App Intents(기능 7)
│  └─ volta.entitlements       #   App Sandbox = false
├─ voltaHelper/                # ② root 헬퍼 데몬 (Command Line Tool) — Xcode 타깃 미연결
│  ├─ main.swift               #   NSXPCListener + RunLoop
│  ├─ HelperListener.swift     #   연결 코드서명 검증
│  ├─ HelperService.swift      #   VoltaHelperProtocol 구현(SMC 쓰기 위임)
│  ├─ SleepWatcher.swift       #   sleep/wake 직접 수신 + IOPMAssertion(기능 2·8)
│  ├─ com.rojiwon.volta.helper.plist  # LaunchDaemon plist
│  ├─ Info.plist               #   바이너리 임베드용
│  └─ voltaHelper.entitlements
├─ Packages/VoltaCore/         # ③ 공유 Swift Package — Xcode 의존성 미연결
│  └─ Sources/VoltaCore/
│     ├─ Models/BatteryReading.swift
│     ├─ Power/PowerMetrics.swift
│     ├─ Policy/{ChargeState,ChargeAction,HelperPolicy,ChargePolicyEngine}.swift
│     ├─ SMC/{SMCKey,SMCFloat,SMCKit,SMARTBattery,SMCService}.swift
│     └─ XPC/{HelperConstants,VoltaHelperProtocol}.swift
│     └─ Tests/VoltaCoreTests (정책·디코딩 단위 테스트)
└─ docs/
```

## 2. 아키텍처 요지

2-프로세스 분리(사용자 설계 그대로):

- **앱**: 비특권. `SMCService`(VoltaCore, actor)로 SMC/AppleSmartBattery를 **읽기**만. `ChargePolicyEngine` 상태머신으로 **판단**. 결정된 동작을 XPC로 헬퍼에 위임. UI는 `@Observable` 바인딩.
- **헬퍼(root)**: `SMCService`로 SMC **쓰기**(충전/어댑터). sleep/wake를 **직접 수신**해, 앱이 사전 푸시한 `HelperPolicy`로 즉시 적용(XPC 왕복 없이). 상한 전까지 `IOPMAssertion`으로 sleep 억제.
- **공유(VoltaCore)**: SMC 레이어·디코딩·정책 엔진·XPC 프로토콜·모델. 플랫폼 의존 코드는 `#if canImport(IOKit)`로 가드.

폴링은 앱에서 10초 주기 `Task` 루프(`BatteryMonitor.tick()`). 상태가 바뀔 때만 헬퍼에 명령(불필요한 SMC 쓰기 방지). 정책 변경 시 즉시 헬퍼에 사전 푸시(기능 8).

## 3. 9개 기능 매핑

| # | 기능 | 구현 위치 | 상태 |
|---|------|-----------|------|
| 1 | Charge Limiter (충전 상한) | `SMCService.setChargingAllowed` + `SMCKeys.chargeInhibit/*Bytes`, UI 슬라이더 | 코드 작성 / 매직값·키 **검증 필요** |
| 2 | 상한까지 Sleep 비활성화 | `SleepWatcher.setSleepInhibit`(IOPMAssertion), `BatteryMonitor.tick`에서 토글 | 코드 작성 / 동작 **검증 필요** |
| 3 | Discharge (어댑터 off) | `SMCService.setAdapterEnabled` + `adapterControl`, UI 토글, 클램셸 경고 | 코드 작성 / 매직값·클램셸 판별 **검증 필요** |
| 4 | 하드웨어 배터리 비율 | `SMARTBattery`(RawCurrentCapacity/DesignCapacity) → `hardwareChargePercent` | 코드 작성 / 키·단위 **검증 필요** |
| 5 | Heat Protection | `ChargePolicyEngine`(temp ≥ ceiling → heatPaused) + UI 토글 | 로직 검증됨(Python) / 온도 키·단위 **검증 필요** |
| 6 | Live Status + 전력 메트릭 | `PowerMetrics` + `SMCFloat.decodeFLT`(PDTR/PPBR/PSTR), `PowerFlowView` | flt 디코딩 검증됨(Python) / 키·부호 **검증 필요** |
| 7 | Apple Shortcuts | `VoltaShortcuts`(App Intents) | 코드 작성 / 빌드 추출 **검증 필요** |
| 8 | 수면 중 충전 중지 | `SleepWatcher`(will-sleep 시 정책 적용) + 사전 푸시 `HelperPolicy` | 코드 작성 / 동작 **검증 필요** |
| 9 | 전원 모드=배터리 bypass | 충전 상한(기능 1)에 흡수: 상한 도달 시 충전 inhibit = 어댑터 직접 급전 | 설계 반영 / **검증 필요** |

## 4. 검증된 것 / 안 된 것 (정직하게)

**알고리즘 수준에서 검증됨 (Python 교차검증, `docs`의 체크리스트 참고):**
- `SMCFloat.decodeFLT` 테스트 벡터(5.0=`00 00 A0 40`, −12.5=`00 00 48 C1`), `decodeSP78`(1.5=`01 80`).
- `ChargePolicyEngine` 상태 전이 8케이스(충전/상한/히스테리시스/방전/과열/강제방전/대기).

**검증 안 됨 (전부 실기 필요):**
- Swift 컴파일 자체(이 환경에 툴체인 없음).
- 모든 SMC **키 문자열**과 **매직값**(CHTE/CHIE 명칭, Tahoe 4바이트 충전값, 어댑터 0x8 등). `batt` 오픈소스의 Tahoe 경로를 근거로 했으나 모델/펌웨어별 상이 가능.
- 온도 키/단위, 전력 키/부호 규약.
- App Sandbox on 상태에서 IOKit 읽기 가부.
- SMAppService daemon 등록/승인, XPC 연결, 코드서명 요구사항.
- IOPMAssertion·sleep 콜백 실동작.

## 5. 빌드 설정(적용 완료, pbxproj)

- `SWIFT_VERSION = 6.0`(앱·테스트·UI테스트 전부)
- `SWIFT_STRICT_CONCURRENCY = complete` + `ARCHS = arm64` (프로젝트 레벨)
- `MACOSX_DEPLOYMENT_TARGET = 26.0`
- 앱: `INFOPLIST_KEY_LSUIElement = YES`(메뉴바 agent), `ENABLE_APP_SANDBOX = NO`, `CODE_SIGN_ENTITLEMENTS = volta/volta.entitlements`
- Xcode 26 기본값 유지: `SWIFT_APPROACHABLE_CONCURRENCY = YES`, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`

## 6. 참고한 외부 근거

- `charlie0129/batt` (Apple Silicon 배터리 제어, Tahoe 충전/어댑터 매직값 근거)
- `mhaeuser/Battery-Toolkit` (Apple Silicon 플랫폼 전원 제어)
- 정확한 SMC 키/값은 위 프로젝트들과도 모델별로 다를 수 있어 **검증 필요**로 분류.
