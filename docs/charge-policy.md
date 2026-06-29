# 배터리 충전 정책 / 사용 흐름 설계

> 상태: **확정·구현 반영**. 충전 동작은 **단일 상한("충전 제한")** 모델이며, 우선순위(과열 > {외출 준비 XOR
> 강제 방전} > 충전 제한)·외출 준비·상호 배타까지 코드에 구현됐다(§5 매핑 참조). 캘리브레이션만 보류.

---

## 1. 배경 / 목표

배터리 수명 연장을 위해 다음을 노린다.

1. **고(高)SoC 체류 최소화** — 100%(또는 높은 충전 상태)에 오래 머무는 것이 셀 열화를 가속하므로, 충전을 상한(max)에서 멈춰 평소 충전량을 낮게 유지한다.
2. **발열 관리** — 충전·강제 방전은 발열을 만든다. 과열 구간에서는 이 동작들을 보류한다.

> 이전의 min/max **밴드** 모델(재충전 하한 + 히스테리시스)은 **단일 상한 모델로 단순화**됐다. 설정값은 **상한(max) 하나**뿐이다.

---

## 2. 충전 제한 정의 + 사용 흐름

### 정의
- **충전 제한 (max, 충전 상한)**: 충전은 이 값에서 멈춘다. 그 위로는 능동적으로 방전시키지 않는다(자연 소모로 내려감).
- 동작은 두 줄로 끝난다:
  - **SoC < max → max까지 충전**
  - **SoC ≥ max → 현재 상태 유지**(충전 억제, 어댑터가 시스템 직접 구동, 능동 방전 없음)

재충전 하한(min)·히스테리시스는 없다. 전원이 연결돼 있고 SoC가 max 미만이면 **항상** max까지 충전한다.

### 사용 흐름 — "데스크 거치 + 가끔 뽑아 씀 → 재연결" (예: max 80)
1. **거치 중(항상 꽂혀 있음)**: SoC가 상한(80%)에 도달하면 → **유지**. 충전을 억제하고 어댑터가 시스템을 직접 구동한다.
2. **뽑아서 외출/이동 사용**: 전원 미연결 → 배터리로 구동, SoC가 떨어진다. (예 80% → 55%)
3. **다시 거치(재연결)**: SoC(55%)가 상한(80%) 미만이므로 → **충전 재개**, 80%까지 채운다.
   - 잠깐만 뽑아 써서 SoC가 79%여도 → 80% 미만이므로 **다시 80%까지 충전**한다(재충전 하한이 없으므로 매 재연결 시 상한까지 채움).
4. **상한 도달 후 다시 유지**로 돌아간다. 1번으로 순환.

---

## 3. 의사결정 표 (모든 플러그인 상태)

표기: SoC = 현재 충전 비율, max = 충전 상한.
"유지"는 **충전 억제 + 능동 방전 없음**(어댑터가 시스템 직접 구동)을 뜻한다.

### 3-1. 충전 제한 (전원 연결, 오버라이드 없음)

| 조건 | 동작 | 상태(개념) | 근거 |
|---|---|---|---|
| 전원 미연결 (언플러그) | 배터리 사용(충전 제한 비적용) | discharging | 언플러그 중엔 그냥 방전 |
| 연결 · SoC < max | **max까지 충전** | charging | 상한 미만이면 충전 |
| 연결 · SoC ≥ max | **능동 방전 없이 유지** | limitReached(유지) | 상한 도달/초과 → 충전 억제, 자연 소모로 내려감 |

### 3-2. 오버라이드 (충전 제한보다 우선하는 사용자/안전 규칙)

| 오버라이드 | 발동 조건 | 동작 | 비고 |
|---|---|---|---|
| **과열 보호(열 인지)** | (기능 켜짐 &) 온도 ≥ 과열 임계 | **충전·강제 방전·외출 준비를 모두 중단**하고 유지(idle)로 식힘. 식으면 재개 | 가장 강한 제약. 발열원(충전·강제 방전)을 멈추는 안전 규칙. 기능이 꺼져 있으면 오버라이드 없음 |
| **강제 방전(force discharge)** | 사용자가 옵트인 + 목표% 설정, SoC > 목표 | 어댑터 급전을 끊어 **목표%까지 능동 방전** → 목표 도달 시 **1회성 완료로 자동 종료(off)** → 충전 제한 정책으로 복귀(전력 연결 시 max까지 재충전) | 1회성. 목표 도달 전 전력이 끊겨 자연 방전으로 목표 이하가 돼도 완료로 본다. 발열·사이클 throughput 비용이 있어 기본 비활성 |
| **외출 준비(트립-프렙)** | 사용자가 수동 발동 | 충전 제한을 일시 무시하고 **100%까지 풀충전** | 일시 오버라이드. 완료/해제되면 **충전 제한 규칙으로 복귀** |

#### 오버라이드 상호작용 — 확정 (안전 최우선)
우선순위: **과열 보호 > {외출 준비 XOR 강제 방전} > 충전 제한.**

- **과열 보호가 가장 강한 제약** (단, **사용자가 과열 보호 기능을 켜둔 경우에만**. 꺼져 있으면 과열 오버라이드 자체가 존재하지 않는다.)
  - 이 배터리 맥락에서 **발열을 만드는 동작은 충전과 강제 방전**이므로(발열원→중단 매핑), 과열 시에는 **충전·강제 방전·외출 준비(=100% 충전)를 모두 중단하고 유지(충전 억제, idle) 상태로 식힌다.** 식으면 원래 충전 제한 규칙으로 복귀.
  - 따라서 "외출 준비 중 과열" 시에도 풀충전을 강행하지 않고 **과열 보류가 우선**한다(확정).
- **외출 준비 ↔ 강제 방전은 상호 배타(동시 활성 불가)**: 방향이 반대(끝까지 채움 vs 끌어내림)이므로 한쪽을 켜면 다른 쪽은 자동으로 꺼진다. 둘이 동시에 켜진 상태는 **존재할 수 없다**(UI/상태 레벨 제약).
- 위 두 제약을 제외하면 충전 제한 로직대로 동작한다.

---

## 4. 상태머신 (상태 / 전이)

### 상태
| 상태 | 의미 |
|---|---|
| `suspended` | SoC를 알 수 없음/초기/비활성. 판단 보류 |
| `charging` | 전원 연결 + SoC < max → 충전 |
| `limitReached` | 유지(충전 억제, 어댑터 직접 구동). SoC ≥ max |
| `discharging` | 전원 미연결 → 배터리 사용 (충전 제한 비적용) |
| `forcedDischarge` | 사용자 강제 방전(옵트인): 목표%까지 어댑터 차단 후 능동 방전. SoC≤목표면 1회성 완료로 자동 해제 |
| `heatPaused` | 과열로 충전 일시정지 |

> "외출 준비(100% 풀충전)"는 **별도 상태를 만들지 않고** 충전을 그대로 `charging`으로 표현한다(AC 연결 & <100%면 charging, 100% 도달 시 `limitReached`로 유지). 즉 충전 제한을 무시하고 100%까지 충전하는 오버라이드다(§5 매핑 참조).

### 전이 (전원 연결 시, 우선순위 높은 것부터)
의사결정 순서로 읽으면 된다 — 위에서 매칭되는 첫 규칙이 그 틱의 상태가 된다.
우선순위는 **과열 보호 > {외출 준비 XOR 강제 방전} > 충전 제한** (안전 최우선).

```
0. SoC 미상                          → suspended
1. 과열 보호 켜짐 & 온도 ≥ 임계         → heatPaused
     (충전·강제 방전·외출 준비를 모두 중단하고 유지=idle로 식힘. 과열 보호가 꺼져 있으면 이 규칙 없음)
2. 외출 준비 활성                      → charging (목표 100%까지)   ┐ 상호 배타
   강제 방전 활성 & SoC > 목표          → forcedDischarge          ┘ (동시 활성 불가)
3. 전원 미연결                         → discharging
4. (충전 제한)
     SoC < max                        → charging
     SoC ≥ max                        → limitReached(유지)
```

전이 요약:
- `discharging` →(재연결, SoC<max)→ `charging` →(SoC=max 도달)→ `limitReached` →(뽑아 씀)→ `discharging`
- 과열 보호가 켜진 상태에서 과열 진입 시 어느 상태든 `heatPaused`로 가서 **충전·강제 방전·외출 준비를 모두 중단**, 식으면 직전 규칙으로 복귀.
- 외출 준비와 강제 방전은 **상호 배타** — 한쪽을 켜면 다른 쪽은 자동으로 꺼진다(동시 활성 상태 없음).
- 강제 방전은 SoC≤목표면 **1회성 완료로 자동 해제(off)** → 충전 제한 정책으로 복귀(전력 연결 시 max까지 재충전). 도달 후 다시 방전하는 무한 루프를 막는다.
- 외출 준비는 사용자가 끌 때까지 유지(해제 시 충전 제한으로 복귀).

---

## 5. 기존 코드 매핑

| 설계 항목 | 매핑되는 코드 | 비고 |
|---|---|---|
| 상태 판단(순수 함수) | `Policy/ChargePolicyEngine.evaluate()` | §4 우선순위대로 구현: ① 과열(발열원=AC 충전 또는 `forceDischargeActive`일 때만 발동) → ② 강제 방전 → ③ 외출 준비(AC & <100% → charging) → ④ 언플러그 → ⑤ 충전 제한 |
| **충전 제한 (max)** | `HelperPolicy.chargeLimit` | 단일 상한. `SoC < limit → charging`, `SoC ≥ limit → limitReached`. 능동 방전 없음 |
| 유지(충전 억제) | `ChargeState.limitReached` → `ChargeAction(allowCharging:false, forceDischarge:false)` | 어댑터 직접 구동 = bypass |
| 충전 | `ChargeState.charging` → `ChargeAction(allowCharging:true, …)` | |
| 강제 방전(1회성) | `HelperPolicy.forceDischargeTarget` + `ChargeState.forcedDischarge` + `ChargeAction.forceDischarge` | 충전 제한 엔진이 만들지 않음. **과열 보호보다 하위**, 외출 준비와 **상호 배타**(아래 참조). 목표까지 1회 방전 후 충전 제한까지 재충전 |
| 강제 방전 1회성 완료(자동 off) | `ChargePolicyEngine.isForceDischargeComplete(reading:policy:)` 판정 → `BatteryMonitor.tick()`이 `forceDischargeTarget = nil`로 자동 해제 | SoC≤목표면 완료(AC 무관). 해제 후 충전 제한 정책으로 복귀해 전력 연결 시 max까지 충전 → 무한 방전↔충전 루프 방지 |
| 외출 준비(100% 풀충전) | `HelperPolicy.tripPrepEnabled` + 엔진 ③분기(`charging`) + UI 토글(`BatteryMonitor.tripPrepEnabled`) | 충전 제한 무시하고 100%까지 충전, 끄면 복귀. **강제 방전과 상호 배타**: `BatteryMonitor` setter가 cross-clear, `HelperPolicy.validated()`/`isWithinBounds`가 fail-safe로 강제(둘 다 활성 시 외출 준비 끔) |
| 과열 보호 | `HelperPolicy.heatProtectionCeiling` + `ChargeState.heatPaused` | 최우선. 온도 ≥ 임계 & (`isACPresent` 또는 강제 방전 능동)에서 발동 → 충전·강제 방전·외출 준비 모두 중단 |
| 언플러그 = 방전 | 엔진의 `guard r.isACPresent else { return .discharging }` | 충전 제한 비적용 |
| UI(충전 제한 게이지) | `volta/ContentView.swift` `ChargeLimitGauge` | 단일 노브 게이지로 max 한 값(20~100%)만 조절 |
| 폴링 → 엔진 → 헬퍼 위임 | `volta/BatteryMonitor.swift` (@Observable) | 10초 폴링, 상태 변화 시 `HelperClient`(XPC)로 위임 |
| 하드웨어 실현(SMC 쓰기) | `SMC/SMCService.swift` (`setChargingAllowed`/`setAdapterEnabled`) + 헬퍼 | probe로 존재하는 키만 write: 충전 억제 CHTE / 어댑터 차단 CHIE→CH0J→CH0I 폴백 / 방전 LED ACLC(외관). 매직값·효과 실기 검증 대상(`docs/device-support.md` §4-1) |
| 효과 검증·**능력별** 비활성 | `Device/ControlEffectVerification.swift`·`Device/ControlCapability.swift`(순수) + `SMCService.verifyControlEffect` + `BatteryMonitor`(샘플링·세대·반영) | 제어 적용 후 거동(충전 멈춤/배터리 방전)을 정착 후 샘플해 확인. 미관찰이면 **그 능력만**(`chargeInhibit`/`adapterDisable`) `ineffective`로 두고 그 능력 의존 기능만 비활성 → 다른 능력 유지. 검증 중 의도가 바뀌면(취소 등) 세대 불일치로 판정 폐기(오탐 방지, `VerificationGating`). 실기 효과는 미검증(`device-support.md` §4-2) |
| 점검(self-test) | `Device/SelfTest.swift`(순수) + `BatteryMonitor.runSelfTest` + `Views/SelfTestView.swift` | 사용자 버튼으로 능력별 실동작 확인 → 능력별 반영/승격(`device-support.md` §4-3, feature-spec §10) |
| 전력 흐름/방향 표시 | `Power/PowerFlow.swift` (`Activity`: charging/discharging/holding/idle) | 유지=holding, 강제/언플러그 방전=discharging |
| 캘리브레이션 | **보류(나중에)** | 이번 설계 범위 밖 |

> 마이그레이션: 이전 밴드 모델의 `dischargeFloor`(재충전 하한)·`chargeStartThreshold`(히스테리시스 시작 임계) 필드는 제거됐다. 구버전 저장값(JSON 키/`UserDefaults` `volta.dischargeFloor`)이 남아 있어도 **무시**된다.

---

## 6. 상한값 선택

설정값은 **충전 상한(max) 하나**다(밴드 폭 개념 없음). 상한이 낮을수록 평균 SoC가 낮게 유지되고, 높을수록 1회 충전으로 더 오래 쓸 수 있다. 상한은 사용자가 조정 가능한 값으로 남긴다(UI의 `ChargeLimitGauge`, 20~100%).
