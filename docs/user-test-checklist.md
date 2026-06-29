# volta 사용자 테스트/확인 체크리스트

내가(사용자가) 실제 Mac(Apple Silicon, macOS Tahoe 26)에서 직접 빌드·실행·검증해야 할 항목. **우선순위 순서**입니다. 위에서부터 막히면 그 단계를 먼저 해결하세요.

> ⚠️ 안전: 충전/방전/어댑터 제어는 하드웨어에 직접 영향을 줍니다. SMC 매직값이 모델과 안 맞으면 예기치 않게 동작할 수 있으니, **충전 제어 쓰기 테스트는 전원/배터리 상태를 지켜보며** 진행하세요.

## P0 — 프로젝트가 빌드되는가 (가장 먼저)

- [ ] **Xcode 타깃 연결**: `remaining-work.md`의 "Xcode 수동 작업"을 먼저 수행 (헬퍼 타깃 추가, VoltaCore 로컬 패키지 추가, 앱/헬퍼에 링크, 헬퍼 plist Copy Files).
- [ ] **VoltaCore 단독 빌드/테스트**: 터미널에서 `cd Packages/VoltaCore && swift build` 그리고 `swift test`.
      - 기대: 정책 8케이스 + flt/sp78 디코딩 테스트 통과. (이 부분은 Python으로 로직만 미리 검증함)
      - ⚠️ `SMCKit`/`SMARTBattery`는 macOS 전용이라 `swift build`가 macOS에서만 됨.
- [ ] **앱 타깃 빌드** 성공 (Swift 6 strict concurrency 에러 없이). 에러 나오면 동시성 격리 경고일 가능성 큼 → 보고.
- [ ] **헬퍼 타깃 빌드** 성공.

## P1 — 메뉴바 앱이 뜨고 읽기가 되는가 (무권한)

- [ ] 앱 실행 시 **Dock에 안 뜨고 메뉴바에만** 아이콘 표시(LSUIElement 확인).
- [ ] 메뉴 팝오버에 충전 %/온도/상태가 표시. **`—`만 뜨면** SMC 읽기 실패 → 키 검증 필요.
- [ ] **기능 4**: 하드웨어 비율(HW %)이 표시되고 OS %와 다를 수 있음 (`SMARTBattery` 키 `RawCurrentCapacity`/`DesignCapacity` 확인).
- [ ] **기능 6**: 전력 흐름(어댑터/배터리/시스템 W)이 합리적 값인지.
      - 핵심 검증: **부호 규약**. 충전 중/방전 중에 배터리 W의 부호가 어떻게 나오는지 기록 → `PowerMetrics`/`SMCFloat` 주석의 가정과 비교.
- [ ] 온도(℃) 값이 현실적인지(예: 25~40). 비현실적이면 `SMARTBattery.Temperature` 단위 가정(0.01K) 수정 필요.

## P2 — SMC 키/매직값 실측 (쓰기 전, 매우 중요)

> 쓰기 전에 **키 가용성**과 **값 의미**를 먼저 확인하세요. 잘못된 키/값 쓰기는 위험합니다.

- [ ] `SMCService`의 키 가용성 프로브(`capabilities`) 결과 확인 — 어떤 키가 존재하는지 로깅.
- [ ] **충전 제어 키**(설계상 `CHTE`)의 실제 FourCC와 4바이트 값 확인.
      - `batt` 근거: Tahoe는 4바이트, 허용=`00 00 00 00`, 중단=`01 00 00 00`. 내 모델에서 맞는지.
      - `SMCKeys.batteryCharge`는 임시값 `BUIC`로 둠 → **실제 충전% 키로 교체 필요**.
- [ ] **어댑터 제어 키**(설계상 `CHIE`)의 FourCC와 값 확인 (`batt` 근거: disable=`0x8`, enable=`0x0`).
- [ ] 전력 키 PDTR/PPBR/PSTR 존재 및 flt 타입 여부.

## P3 — 헬퍼 등록 & XPC (특권 경로)

- [ ] 앱에서 "설치" → `SMAppService.daemon.register()` 성공.
- [ ] **시스템 설정 > 일반 > 로그인 항목**에서 헬퍼 승인(상태가 "승인 필요"→"활성").
- [ ] XPC `getVersion`이 헬퍼 버전 문자열 반환(연결 성공).
- [ ] 코드서명 요구사항 검증 통과 (`HelperListener`의 requirement 문자열에 **실제 팀 ID** 반영했는지). 현재 `$(DEVELOPMENT_TEAM)` 자리표시자 → 하드코딩/치환 필요.

## P4 — 핵심 기능 실동작 (쓰기, 하드웨어 영향)

- [ ] **기능 1**: 상한을 현재 충전량보다 낮게 설정 → 충전이 멈추는지(어댑터 연결 상태에서 % 정체).
- [ ] **기능 1 해제**: 상한을 올리면 다시 충전되는지. 히스테리시스(상한-5%) 동작 확인.
- [ ] **기능 5**: (가능하면) 부하로 온도 올렸을 때 `heatPaused` 진입하는지. 무리한 발열 유도는 금지.
- [ ] **기능 3**: 강제 방전 토글 → 어댑터 연결 중에도 배터리 % 감소하는지. **클램셸(덮개 닫고 외부 모니터)에서는 미지원**임을 확인(경고 노출).
- [ ] **기능 2**: 상한 도달 전 충전 중 잠자기 억제되는지(`pmset -g assertions`로 PreventSystemSleep 확인).
- [ ] **기능 8**: 잠자기 진입 시 충전 중단되는지(수면 중 충전 허용 OFF일 때). 깨어나면 정책 재적용.
- [ ] **기능 7**: 단축어 앱에 "충전 상한 설정/강제 방전/배터리 상태"가 노출되고 실행되는지.
- [ ] **기능 9**: 상한 도달 시 어댑터 직접 급전(배터리 유지) 동작 확인.

## P5 — 마감 품질

- [ ] 비정상 종료/로그아웃 시 헬퍼가 충전을 **기본 허용 상태로 복구**하는지(배터리 영구 제한 방지).
- [ ] notarization: Developer ID 서명 + 공증으로 배포 가능한지.
- [ ] 무료 Personal Team으로 SMAppService daemon 등록이 되는지(안 되면 유료 계정 필요 — 확인).

## 결과 기록란

각 항목 옆에 ✅/❌ 와 관찰값(특히 SMC 키 FourCC, 매직값, 전력 부호)을 적어 주세요. 그 값으로 코드의 "검증 필요" 자리표시자를 확정값으로 교체하면 됩니다.

---

# 부록 A — 정밀 검증 명령 / 기대 출력 / 실패 기준

> ⚠️ **안전 최우선.** 충전/어댑터 SMC 쓰기는 하드웨어에 직접 작용합니다. 아래 "안전·롤백"을 먼저 읽으세요.

## A-0. 안전 · 롤백 (먼저 숙지)

- **충전이 안 돌아올 때(가장 중요):** 헬퍼가 충전을 막아둔 상태로 멈추면 배터리가 계속 빠집니다. 복구 순서:
  1. 앱에서 충전 상한을 100으로 올리고 강제 방전 OFF.
  2. 안 되면 헬퍼 내림: 터미널 `sudo launchctl bootout system/com.rojiwon.volta.helper` (또는 앱에서 "헬퍼 제거").
  3. 그래도 충전 불가하면 **SMC 리셋**: Apple Silicen은 종료 후 10초 대기 후 부팅(또는 그냥 재부팅)하면 SMC 충전 제어가 기본값으로 돌아옵니다.
  - 코드 안전장치: 헬퍼는 SIGTERM(bootout) 시 `restoreSafeDefaults()`로 충전 허용+어댑터 복원을 시도합니다(실기 검증 필요).
- **첫 쓰기 테스트는 배터리 50~70%에서**, 전원 연결 상태로, 화면 보며 진행. 한 번에 하나의 키만.
- 위험 동작(어댑터 차단=강제 방전)은 **클램셸(덮개 닫고 외부 모니터) 금지** — 절전/전원 문제 소지.

## A-1. 무권한 읽기 검증 (쓰기 전)

배터리 IORegistry 원본 확인 (기능 4 근거):
```
ioreg -r -c AppleSmartBattery -w0 | grep -E "RawCurrentCapacity|DesignCapacity|CurrentCapacity|Temperature|CycleCount|IsCharging|ExternalConnected"
```
- 기대: `RawCurrentCapacity`, `DesignCapacity` 정수. `Temperature`(예: 약 3000 = 30.00℃면 0.01K가 아니라 0.01℃·…**단위 확인**), `IsCharging`=Yes/No.
- 실패 기준: 키가 안 보이면 `SMARTBattery`의 키 이름을 이 출력에 맞게 수정.
- **온도 단위 결정**: `Temperature` 원시값을 코드 가정(0.01K → ℃=v/100−273.15)과 대조. 결과가 비현실적(예: −250℃)이면 단위는 0.1℃ 또는 0.01℃ → `SMARTBattery.swift` 수정.

전원/어댑터 상태:
```
pmset -g batt
system_profiler SPPowerDataType | grep -iE "Wattage|Charging|Condition|Cycle"
```

## A-2. SMC 키/매직값 실측 (쓰기 전, 핵심)

- 가능하면 오픈소스 CLI로 키 존재/현재값을 먼저 확인(읽기 전용): `batt`(charlie0129) 또는 `smc`(hholzschu/floe) 등.
- 우리 코드의 자리표시자와 대조해 **FourCC 확정**:
  - `SMCKeys.batteryCharge`(현재 임시 `BUIC`) → 실제 충전% 키.
  - `chargeInhibit`(설계명 CHTE) / `adapterControl`(설계명 CHIE)의 실제 키와 Tahoe 매직값.
    - 근거(batt, Tahoe 경로): 충전 4바이트 허용=`00 00 00 00`/중단=`01 00 00 00`, 어댑터 1바이트 enable=`0x0`/disable=`0x8`.
  - 전력: `PDTR`/`PPBR`/`PSTR` 존재 및 flt 타입.
- 실패 기준: 키가 없거나 길이가 다르면 절대 그 값으로 쓰지 말 것 → 코드 수정 후 재시도.

## A-3. 헬퍼 등록 / XPC

```
# 등록 상태
sudo launchctl print system/com.rojiwon.volta.helper | head -30
# 로그 스트림(헬퍼/앱)
log stream --predicate 'process == "voltaHelper" OR process == "volta"' --info
```
- 기대: 데몬 state = running, MachService 등록됨. 앱 `getVersion`이 문자열 반환.
- **코드서명**: `HelperConstants.developmentTeamID`를 실제 팀ID로 설정해야 연결이 수락됨(미설정 시 의도적으로 전부 거부 = fail-closed). `HelperListener` 로그에 "연결 거부" 뜨면 팀ID 미설정.

## A-4. 기능별 실동작 + 검증 명령

- **기능 2(sleep 억제)**: 충전 중 상한 전 상태에서
  ```
  pmset -g assertions | grep -i PreventSystemSleep
  ```
  기대: volta의 assertion 표시. 상한 도달 시 사라짐.
- **기능 8(수면 중 충전 중지)**: "수면 중 충전 허용" OFF 상태로 잠자기 → 깨운 뒤 로그에서 will-sleep 시 충전 차단 적용 확인. 잠들기 전 동기 적용(`applyChargingForSleepBlocking`)이 IOAllowPowerChange보다 먼저 도는지 로그 타임스탬프로 확인.
- **기능 1/3 실동작**: 상한을 현재%보다 낮춤 → `pmset -g batt`로 % 정체(충전 정지) 확인. 강제 방전 ON → 연결 중에도 % 감소.
- 각 쓰기 후 즉시 `ioreg`/`pmset`로 반영 확인. 비정상 시 A-0 롤백.

## A-5. 자동 테스트(로직)

```
cd Packages/VoltaCore && swift test
```
- 기대: 정책/검증/디코딩 테스트 전부 통과(이 환경에선 Python으로 동일 35케이스 통과 확인함, `verification-results.md`).
