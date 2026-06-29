# CLAUDE.md

volta 코드베이스에서 작업할 때 맥락을 빠르게 복원하기 위한 문서. (Claude Code / 협업자용)

## 작업 규칙 (에이전트)

- **git worktree를 만들지 말고 `main` 브랜치에서 직접 작업한다.** 사용자가 결과를 즉시 빌드·확인할 수 있어야 하기 때문이다. (Cowork/에이전트 작업 공통.)
- **동시 작업 충돌 조율은 dispatch 오케스트레이터가 담당**하므로, 충돌 회피를 위해 별도 브랜치/worktree를 파생하지 않는다.

## 프로젝트 개요

**volta** — macOS 배터리 충전 관리 메뉴바 앱(AlDente 대체). 배터리 수명 연장을 위해
충전 상한·하한(min/max 밴드)을 강제하고, 과열 보호·강제 방전·수면 중 충전 중단 등을 제공한다.

- **대상**: macOS Tahoe 26 + Apple Silicon 전용. (Intel/구버전 미지원 가정.)
- **방식**: 소프트웨어로 SMC 충전 억제(CHTE 등)를 조작 → 하드웨어 잔량을 임의 % 밴드에 유지.
- **UI 컨셉**: LSUIElement(독 아이콘 없음) 메뉴바 글리프 + 팝오버.

## 아키텍처

3개 구성요소가 **VoltaCore**(순수 로직 SwiftPM 라이브러리)를 공유한다.

```
┌────────────┐   XPC(JSON HelperPolicy)   ┌──────────────┐
│  volta(앱)  │ ───────────────────────▶  │ voltaHelper  │ (root daemon)
│  LSUIElement│   SMAppService 등록        │ SMAppService │
└─────┬──────┘                            └──────┬───────┘
      │ 읽기(비특권)                              │ 쓰기(root): SMC CHTE/CHIE
      ▼                                          ▼
   IORegistry/SMC 읽기                        SMC 쓰기 + sleep/wake 처리
         └──────────── VoltaCore(공유) ───────────┘
```

- **앱(volta)**: 메뉴바 UI + 폴링. `BatteryMonitor`(@Observable)가 10초마다 `SMCService.readBattery()`로
  읽고 `ChargePolicyEngine`으로 다음 상태를 판단해, 변화 시 `HelperClient`(XPC)로 헬퍼에 동작 위임.
  쓰기 권한 없음(읽기만).
- **헬퍼(voltaHelper)**: root 데몬. XPC로 받은 동작을 SMC 쓰기로 실현. `SleepWatcher`가
  sleep/wake를 직접 수신해, 앱이 사전 푸시한 `HelperPolicy`로 XPC 왕복 없이 즉시 적용.
- **VoltaCore**: 부수효과 없는 로직 — 상태머신, 정책/검증, SMC/IORegistry 접근, XPC 프로토콜. 단위 테스트 대상.

**핵심 상태머신** `ChargePolicyEngine.evaluate(reading, policy, previous) -> ChargeState`
(우선순위 순): ① 사용자 강제 방전(목표 초과) → ② 과열(heatPaused) → ③ AC 미연결(discharging)
→ ④ **min/max 밴드**(아래). 상태→하드웨어 의도는 `ChargeAction.from(state)`(allowCharging/forceDischarge).

## 기능과 현재 상태

- **충전 min/max 밴드** (`dischargeFloor`=min, `chargeLimit`=max): **하한은 필수값(항상 활성)**.
  - %<min → 상한까지 충전(charging). 히스테리시스로 아래로 빠지면 max까지 충전 후 유지.
  - %≥min → 유지(limitReached, 충전 inhibit·방전 안 함 = bypass). **상한 초과여도 그냥 유지 — 자동 방전 없음.**
  - 검증: 항상 min<max로 클램프.
  - **`forcedDischarge`는 밴드가 만들지 않음** — 오직 사용자 수동 "강제 방전"(목표%까지 한 사이클, AC 차단) 전용이며, 밴드보다 우선(①).
  - UI: 팝오버의 **RangeSlider**(핸들 2개)에서 하한·상한 동시 설정.
- **과열 보호**: temp ≥ ceiling(기본 40℃) & AC면 충전 일시정지. 밴드보다 우선.
- **상한 도달까지 잠자기 억제**(`inhibitSleepUntilLimit`): IOPMAssertion으로 sleep 방지(기능 2).
- **수면 중 충전 중단(유지)**: **기본 동작 = 수면 진입 시 충전 inhibit(현재 잔량 유지)**.
  자는 동안 상한에서 못 멈추니 과충전 방지. opt-in(`allowChargingWhileAsleep=true`)으로 수면 중 상한까지 충전 허용 가능.
  헬퍼: sleep 직전 동기 inhibit(`applyChargingForSleepBlocking`), wake 시 `applyCurrentPolicy` 재적용.
- **강제 방전**(`forceDischargeTarget`): 사용자가 목표%까지 의도적으로 배터리 소모(어댑터 차단).
- **메뉴바 글리프**: 상태별 배터리 아이콘 + 배지/halo. SwiftUI를 `ImageRenderer`로 래스터화해 NSStatusItem에 렌더.
- **전력 흐름 뷰**(팝오버, AlDente식 Sankey): 좌(소스)→우(sink) L→R. 어댑터/방전배터리 → 노트북/충전배터리.

## 파일·디렉터리 맵

```
volta/                      앱 타깃(메뉴바 UI)
  voltaApp.swift            진입점(LSUIElement)
  BatteryMonitor.swift      ★ 중심 @Observable: 폴링 → 엔진 → 헬퍼 위임 + 설정(UserDefaults) + DEBUG 프리뷰
  ContentView.swift         팝오버 UI(충전범위 RangeSlider·토글·전력흐름·프리뷰)
  Views/
    MenuBarController.swift  NSStatusItem 관리 + ImageRenderer 래스터화
    MenuBarLabel.swift       메뉴바 글리프(배터리+배지+halo)
    PowerFlowView.swift      ★ 전력 흐름 Sankey 뷰
    HelperStatusView.swift   헬퍼 설치/연결 상태
  Helper/HelperClient.swift  XPC 클라이언트
  Intents/VoltaShortcuts.swift  App Intents(단축어)
voltaHelper/                root 데몬
  main.swift, HelperListener.swift, HelperService.swift  XPC 수신 + 정책 보관/적용
  SleepWatcher.swift         IORegisterForSystemPower 콜백(sleep/wake)
Packages/VoltaCore/Sources/VoltaCore/
  Policy/  ChargePolicyEngine(상태머신)·ChargeState·ChargeAction·HelperPolicy(정책+검증/Codable)
  Power/   PowerMetrics(전력 W)·PowerFlow(소스→sink 엣지 모델)
  SMC/     SMCService(actor, 읽기/쓰기 직렬화)·SMCKit·SMCKey·SMCFloat·SMARTBattery(IORegistry)
  XPC/     VoltaHelperProtocol·HelperConstants
  Models/  BatteryReading
  Tests/   PolicyAndDecodeTests·PowerFlowTests (swift test로 실행)
docs/      설계/검증 문서(한국어): aldente-ux-parity, implementation-status, remaining-work 등
build.sh   빌드 래퍼
```

## 빌드 / 테스트

```bash
./build.sh            # 앱 빌드 (xcodebuild -project volta.xcodeproj -scheme volta -configuration Debug)
./build.sh run        # 빌드 후 실행
./build.sh test       # = cd Packages/VoltaCore && swift test  (순수 로직 테스트)
```

- 앱 산출물: `DerivedData/Build/Products/Debug/volta.app` (직접 `open` 가능).
- 로직 테스트: `cd Packages/VoltaCore && swift test`. 현재 **60개 통과**(엔진·밴드·검증·디코드·전력·폴백).
- ⚠️ 메뉴바/팝오버 시각은 헤드리스 검증이 어려워, **오프라인 `ImageRenderer`로 PNG를 렌더**해 확인하는 패턴을 쓴다
  (뷰 로직을 `FNode` 스텁으로 미러링 → 고정 파동위상으로 결정적 렌더 → md5 회귀 비교).

## 설계 결정과 근거 (재방문 시 주의)

- **⚠️ `@ViewBuilder` 헬퍼의 부분 알파 평탄화**: 메뉴바 글리프에서 palette 렌더의 부분 투명(예 0.7)을
  `@ViewBuilder` 헬퍼로 빼면 1.0으로 평탄화되는 현상 발생. → 알파가 중요한 렌더는 **인라인**으로 두고,
  추출 후엔 반드시 렌더 결과(cgImage/PNG) 동일성 확인. (PowerFlowView 리팩터도 이 방식으로 픽셀 동일 검증함.)
- **메뉴바 글리프**: `.symbolRenderingMode(.palette)` + 테두리 반투명, 배지/halo 분리(`.blendMode(.destinationOut)`+`.compositingGroup()`).
  `.primary`는 알파 0.85라 불투명이 필요하면 `.black` 사용.
- **전력 흐름 Sankey 규칙**(PowerFlowView):
  - 노드(아이콘) 1개당 셀 1개. 같은 쪽 노드 2개면 셀 2개를 `cellGap`만큼 벌려 분리.
  - 셀 높이: 한쪽 2셀이면 반대쪽 단일(허브) 셀 = 두 셀 높이의 **합**(채널이 허브 면을 꽉 채워 합류). 양쪽 단일이면 max로 통일.
  - 채널 두께 = 그 채널이 혼자 닿는 쪽 셀 면 높이(uniform, 가운데 오목 없음). 소스→sink S곡선 연결. 셀 채널쪽 변은 각짐(`UnevenRoundedRectangle`).
  - 셀·채널 같은 불투명 회색(`Metrics.surface`), 통합 단일 그림자(`.compositingGroup`), 채널 안엔 통일색 파동만.
  - 활성 흐름 0(빈 그래프)면 빈 노드 인덱싱 크래시 방지용 guard + "전력 흐름 없음" 표시.
  - 조정 노브는 `Metrics` 상수 섹션에 모음(cellW/cellGap/channelGap/height/corner/surface/channel 등).

## ⚠️ 미검증 / 실기 확인 필요

- **SMC 전력 키 PDTR/PPBR/PSTR**(어댑터/배터리/시스템 W, IEEE754 LE): 모델별로 **안 읽힐 수 있음**(가정).
  → 이 맥에서 nil이라 **IOKit 폴백** 추가: 배터리 W = `AppleSmartBattery.Amperage(mA)×Voltage(mV)`,
  어댑터 delivered = `AdapterDetails.Current×AdapterVoltage`, 시스템 W = `adapter − battery(부호)`. (SMC 우선, 없으면 폴백.)
- **배터리 전력 부호 규약** `PowerFlow.batteryPositiveMeansCharging`(=true, +충전/−방전): SMC PPBR 부호는 미검증.
  IOKit Amperage는 +충전 규약(확인됨). 부호가 다르면 이 상수 한 곳에서 뒤집는다.
- **SMC 쓰기 매직값 CHTE(충전 억제)/CHIE(어댑터 차단)**: 키/바이트값은 모델별 차이 가능 → **실기 검증 필요**.
  클램셸(덮개 닫힘)에서 강제 방전 미지원 가능.
- **어댑터 정격**: `AdapterDetails["Watts"]`(실측 40W 확인). delivered와 구분(rated 우선 표시).
- **온도 단위**: ✅ 확정 — `AppleSmartBattery.Temperature`는 **1/100 ℃(centi-Celsius)**, ℃=raw/100.
  (실측 raw 3020→30.2℃. 과거 0.01K 가정으로 273.15를 빼 -242.9℃ 버그 → `SMARTBattery.celsiusFromCentiCelsius`로 수정, 비현실값 가드.)
- 헬퍼(root/XPC/sleep)는 환경상 실기 빌드에서만 동작 검증 가능. SMAppService 등록·승인 흐름 실기 확인 필요.

## SMC 쓰기(배터리 유지) 활성화 — 권한·셋업 (사용자 몫)

실제로 충전을 억제/유지(SMC 쓰기)하려면 아래 셋업이 필요하다. 모두 **실기/Xcode 작업이라 사용자가 직접** 한다.

- **왜 헬퍼가 필요한가**: SMC 쓰기는 **root 권한** 필요. 앱(비특권)은 읽기만 하고, 쓰기는 **root 데몬(voltaHelper)** 이 XPC로 대행.
- **등록/승인**: 헬퍼는 **`SMAppService`(macOS 13+)** 로 등록(`SMAppService.daemon(plistName:)`). 첫 등록 시 사용자가
  **시스템 설정 → 일반 → 로그인 항목 → 백그라운드에서 허용** 에서 승인해야 활성화된다. (앱이 `registerIfNeeded()` 호출.)
- **자기 맥 테스트는 무료**:
  - **무료 Apple ID**의 자동 **Apple Development** 서명으로 로컬에서 헬퍼 등록·실행 가능(개인 팀).
  - **SMC 쓰기 자체는 root만 필요하고 특별한 entitlement/서명 불요** — 데몬이 root로 돌면 됨.
  - **SIP 비활성화 불필요**(kext 미사용, IOKit/SMC 유저스페이스 접근).
- **유료 $99 Developer Program은 배포 단계에서만**: 다른 맥에 나눠주려면 **Developer ID 서명 + 공증(notarization)** 필요(여기서 유료 계정 필요). **App Store 배포는 불가**(권한 모델상). 자기 맥 개발/사용엔 불필요.
- **선행 셋업(Xcode)** — ✅ pbxproj에 이미 반영됨(타깃/패키지/동봉/서명). 다른 서명 팀으로 바꿀 때만 재확인:
  1. **헬퍼 Command Line Tool 타깃** 빌드 + **LaunchDaemon plist**(`com.rojiwon.volta.helper.plist`) 연결
     (plist의 `Label`/`MachServices`가 `HelperConstants.daemonPlistName`/`machServiceName`와 일치해야 함).
  2. **서명 팀은 `Signing.xcconfig` 한 줄(`DEVELOPMENT_TEAM`)** 로 중앙화됨(프로젝트 base config → 전 타깃 상속).
     다른 팀으로 바꿀 땐 **이 한 줄만** 교체. (현재 `<DEVELOPMENT_TEAM>`.)
     XPC 팀 검증은 `HelperConstants`가 **자기 서명에서 런타임 파생**(SecCode)하므로 코드는 손대지 않는다 — 서명 팀과 자동 일치(fail-closed). 자세히는 `docs/signing-checklist.md`.
     ⚠️ Apple Development 인증서 **CN**의 개인 식별자(예 `CJ576XA3C2`)는 OU(=TeamIdentifier)가 아니니 혼동 금지.
  3. 앱·헬퍼 **서명 팀 일치**(같은 xcconfig 상속) + 헬퍼를 앱 번들 `Contents/Library/...` 에 포함(CopyFiles).
- **검증**: 등록·승인 후 충전 상한/유지가 실제로 먹는지(잔량이 밴드에서 멈추는지), 강제 방전 시 어댑터 차단이 동작하는지
  실기에서 확인. CHTE/CHIE 매직값(위 "미검증")이 모델별로 맞는지도 이때 함께 검증.
