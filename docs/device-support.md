# 기기 지원 / Capability Gating

> volta는 **Apple Silicon 전용**이다. 지원되지 않는 기기에서는 SMC 제어를 전부 비활성화한다(fail-safe).
> 이 문서는 "어떤 기기에서 충전 제어를 활성화할지"의 판별 규칙과 현재 상태를 관리한다.

## 1. 판별 입력 (탐지)
1차 분기 기준은 **아키텍처 + 모델 식별자**다.

| 입력 | 소스 | 예시 |
|---|---|---|
| 아키텍처 | `sysctl hw.machine` | `arm64` / `x86_64` |
| Apple Silicon 여부 | `sysctl hw.optional.arm64` (== 1) | `1` |
| 모델 식별자 | `sysctl hw.model` | `Mac17,5` |
| macOS 버전 | `ProcessInfo.operatingSystemVersion` | `26.5.1` |
| 펌웨어/SMC 지문 | (참고용, 현재 미수집) | — |

- 펌웨어/SMC 버전은 **참고 지문**일 뿐 1차 분기 기준이 아니다. 쉽게 못 읽으면 nil로 둔다(현재 nil). 실기 read-back 경로는 팀 계정 후 헬퍼에서 채울 자리.
- 코드: `VoltaCore/Device/DeviceInfo.swift` (`DeviceInfo.current`).

## 2. 지원 범위
- **지원**: `hw.optional.arm64 == 1`(Apple Silicon) **이고** 모델 식별자가 allowlist에 등록된 경우.
- **미지원**: Intel(x86_64) 머신, 또는 arm64여도 allowlist 미등록 모델.

## 3. 미지원/미등록 기기에서의 fail-safe 동작
- **SMC 쓰기 no-op**: `SMCService.setChargingAllowed` / `setAdapterEnabled`가 지원 판정 false면 아무것도 쓰지 않고 반환한다. (읽기/모니터링은 그대로 동작.)
- **UI 비활성 + 안내**: 팝오버에서 충전 제한 게이지·배터리 모드 셀렉터 등 제어 섹션이 `.disabled` 처리되고, 상단에 미지원 사유 안내가 표시된다(기존 클램셸/헬퍼 미설치 안내와 같은 톤).
- 코드: `VoltaCore/Device/DeviceSupport.swift` (`DeviceSupport.evaluate`), `SMCService`의 쓰기 게이트, `BatteryMonitor.isControlSupported`, `ContentView`의 안내/비활성.

## 4. allowlist + 검증 상태
allowlist 항목은 **(등록 모델들) → 사용할 SMC 키 세트 + 검증 상태**를 함께 갖는다.

검증 상태(`VerificationStatus`):
- `verifiedOnHardware` — 실기에서 SMC 키/매직값/효과까지 검증됨.
- `mappedUnverified` — 키 세트는 매핑됐으나 **효과 미검증**.

현재 allowlist(`DeviceSupport.allowlist`):

| 모델 | 아키텍처 | SMC 키 세트 | 검증 상태 |
|---|---|---|---|
| `Mac17,5` | arm64 | `tahoe-default` (SMCKeys: CHTE/CHIE/BUIC/…) | **mappedUnverified** |

> ⚠️ **실기 SMC 효과 검증은 유료 Apple Developer 팀 계정 도입 후 진행한다.** 현 단계에서는 privileged helper(`SMAppService`) 서명·설치가 불가해 root 데몬으로 SMC 쓰기를 실제 적용/검증할 수 없다. 따라서 이 맥(Mac17,5)도 키 매핑은 했으나 효과는 검증 전이라 `mappedUnverified`로 솔직히 표기한다. 효과 검증(write → read-back 비교) 훅 자리는 `SMCService.verifyControlEffect()`에 마련돼 있으나 현재 no-op이다.

### 4-1. SMC 키 세트 / probe 기반 선택 (write 경로)
`oss actuallymentor/battery` 정합. write 경로(`SMCService`)는 **하드코딩 대신 probe로 존재하는 키만 선택**해 쓴다(blind-write 금지). 키 존재는 `SMCKit.keyExists`(메타정보 `readKeyInfo`)로 확인 — write-only 제어 키에서 값-읽기 probe의 false-negative를 피한다.

| 기능 | 키(우선순위) | 값(차단/해제) | probe 없을 때 |
|---|---|---|---|
| 충전 억제 | `CHTE`(단일) | 중단 `01000000` / 허용 `00000000` (4B) | no-op(충전 제어 비활성) |
| 어댑터 차단(강제 방전) | `CHIE` → `CH0J` → `CH0I` (폴백 체인) | CHIE `08`/`00`, CH0J·CH0I `01`/`00` (1B) | 셋 다 없으면 강제 방전 비활성 |
| 방전 중 MagSafe LED(외관) | `ACLC` | 시작 `01` / 해제 `00` (1B) | LED 미설정(기능 무관, 강제 방전과 분리) |

- 선택 로직은 순수 함수 `SMCKeySelection`(테스트됨). 어댑터는 `adapterFallbackChain`의 첫 가용 키만 사용.
- **구형 `CH0B`/`CH0C`(Intel 듀얼 충전 억제)는 의도적으로 미사용** — Apple Silicon 전용이라 불필요.
- `keyProfile`(allowlist 필드)은 **정보용 라벨**이며, 실제 키 선택은 위 런타임 probe가 결정한다.
- ⚠️ 키 FourCC/매직값/효과는 **모두 미검증**(유료 팀/실기 전). 특히 CHIE 폴백 필요 여부는 실기에서만 확정.

### 4-2. 효과 검증(행동 기반) + **능력별** 비활성
키가 존재해(probe) write까지 됐더라도 **실제로 거동이 바뀌는지**는 별개다. 제어 적용 후 배터리/전력 거동을 관찰해 효과를 확인하고, 안 먹으면 런타임에 그 제어를 끈다. **단위는 기기 전체가 아니라 "능력(capability)"** 이다.

- **능력(capability) 단위**: 제어를 능력별로 구분한다 — `chargeInhibit`(CHTE) / `adapterDisable`(CHIE→CH0J→CH0I). 한 능력이 안 먹으면 **그 능력에 의존하는 기능만** 가려지고(`ControlCapabilityState.ineffective`), 다른 능력 기능은 유지된다. (기능→능력: 충전 제한·과열·수면중단·외출준비·잠자기억제 → `chargeInhibit`, 강제 방전 → `adapterDisable`.) 노출 판정은 순수 `ControlAvailability.isFeatureAvailable(...)`.
- **무엇을 보나(거동)**: write-only 키(CHTE/CHIE)는 값 read-back을 신뢰 못 하므로 **거동**으로 본다.
  - 충전 억제(CHTE): 적용 직전 충전 중 → 이후 멈추면 `observed`, 여전히 충전이면 `notObserved`.
  - 어댑터 차단(CHIE/CH0J/CH0I): AC 연결 & 충전/유지였다가 → 이후 방전(배터리에서 빠짐)이면 `observed`, 안 빠지면 `notObserved`.
- **정착/샘플링**: SMC/OS 반영 시간차가 있어 **정착 지연 후 수 틱 샘플링**해 판정(즉시 판정 금지). 초기 샘플 버리고, 최소 결정 샘플 미만/조건 불충족/노이즈면 `inconclusive`(강등 안 함).
- **헬퍼 write 성공 시에만 검증(오탐 방지)**: 효과 검증은 **헬퍼로 SMC write가 실제 수행(성공)된 경우에만** 돈다. 미연결/실패면 write 미수행 → 검증·강등을 하지 않는다. 게이트: `ControlEffectVerifier.shouldVerify(writePerformed:controlSupported:)`.
- **⭐ stale 판정 폐기(취소 후 상태 오판 방지)**: 검증은 정착~샘플(~30초) 뒤 **비동기**로 판정한다. 그 사이 사용자가 제어를 바꾸거나 끄면(예: **강제 방전→없음으로 취소** → 어댑터 재연결), 검증기가 "취소 후 상태(=방전 아님)"를 보고 `notObserved`로 **오판**할 수 있다. 이를 막으려고 **능력별 세대 카운터**(적용값 변화마다 증가)를 예약 시점에 캡처하고, 판정 시점에 세대가 다르거나 그 의도가 더 이상 적용 중이 아니면 **폐기**한다(강등 금지). 게이트: 순수 `VerificationGating.shouldJudge(scheduledGeneration:currentGeneration:intentStillApplied:)`. — 빠른 토글에도 stale 판정이 남지 않는다.
- **헬퍼 부재면 비활성 자동 해제**: 헬퍼 미연결은 능력 비활성과 구분해 `HelperStatusView`로만 안내하고, 잘못 남은 능력 `ineffective`는 `ControlCapabilityState.clearedIfWriteUnavailable(helperReachable:)`로 되돌린다.
- **능력별 안전 수렴(fail-safe)**: `notObserved`면 그 능력만 `ineffective`로 두고 **그 능력만 안전 복원**(충전 억제 실패→충전 허용·잠자기억제 해제·외출준비 해제 / 어댑터 차단 실패→어댑터 정상·강제방전 해제). 다른 능력은 건드리지 않는다. (런타임 상태 — 저장 안 함, 앱 재시작 시 base로 복귀.)
- 코드: 판정 `ControlEffectVerifier.judge(...)`·게이팅 `VerificationGating`·능력맵 `ControlCapabilityState`(전부 순수, 단위 테스트). 트리거/세대/샘플/응답은 `BatteryMonitor`.
- ⚠️ **판정은 "주어진 샘플상"일 뿐 실기 효과 검증이 아니다.** 실제 효과/강등이 맞게 도는지는 서명된 root 헬퍼·실기에서만 확정. `verifiedOnHardware` 승격도 그때.

### 4-3. 점검(self-test)으로 사용자 트리거 검증·승격
위 4-2는 정상 운영 중 제어가 *처음 적용될 때* 자동으로 한 번 검증한다. **점검(self-test)** 은 같은 거동 검증을 **사용자가 버튼으로** 능동 실행하는 경로다(기능 스펙 §10).
- 제어를 단계별로 직접 적용→관찰→복원하고, 결과를 **능력별** `SelfTest.resolvedCapabilities(base:results:)`(순수)로 반영한다.
- **한 능력 `notWorking` → 그 능력만 `ineffective`**(그 능력 의존 기능만 가려짐, 다른 능력 유지). **모든 단계 `working` → `mappedUnverified`→`verifiedOnHardware` 승격**(`SelfTest.resolvedSupport`/`promotedToVerified()`).
- 판정 불가(어댑터 미연결/충전 아님/노이즈)는 강등·승격 둘 다 하지 않는다(불확실 보수).
- 런타임 상태(저장 안 함). 코드: 순수 로직 `VoltaCore.SelfTest`(단위 테스트 `SelfTestTests`/`ControlCapabilityTests`), 라이브 오케스트레이션 `BatteryMonitor.runSelfTest`.

## 5. 현재 이 기기의 탐지 결과 (기록)
작업 기기에서 실제 조회한 값:

| 항목 | 값 |
|---|---|
| 아키텍처(`hw.machine`) | `arm64` |
| Apple Silicon(`hw.optional.arm64`) | `1` |
| 모델 식별자(`hw.model`) | `Mac17,5` |
| 칩 | Apple A18 Pro |
| macOS | 26.5.1 (build 25F80) |
| 판정 | **supported(mappedUnverified)** — allowlist 등록, 효과 미검증 |

## 6. 새 모델 추가 절차(요약)
1. 대상 기기에서 §1 입력값(특히 `hw.model`) 조회.
2. `DeviceSupport.allowlist`에 모델 추가 — 우선 `mappedUnverified`로 등록.
3. (팀 계정 확보 후) 헬퍼 설치 → SMC 쓰기 효과를 read-back으로 검증 → `verifiedOnHardware`로 승격.
