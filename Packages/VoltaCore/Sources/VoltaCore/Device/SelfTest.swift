//
//  SelfTest.swift
//  VoltaCore
//
//  "점검(self-test)" — 사용자가 직접 눌러 각 제어 기능이 **이 기기에서 실제로 동작하는지**
//  확인하는 기능의 순수 로직. 제어를 하나씩 적용 → 기존 행동 기반 효과검증(ControlEffectVerifier)
//  으로 거동을 관찰 → 결과(동작함/동작 안 함/판정 불가)를 내고, 그 결과로 DeviceSupport 검증상태를
//  갱신(실패 시 강등, 전부 동작 시 verifiedOnHardware 승격)한다.
//
//  이 파일은 **부수효과 없는 오케스트레이션/판정 로직**만 둔다(단위 테스트 대상). 실제 SMC 적용·
//  배터리 샘플링·복원 같은 라이브 IO는 앱 계층(BatteryMonitor)이 수행하고, 그 결과(before/after
//  reading)를 여기 순수 함수에 넘겨 판정한다.
//
//  ⚠️ ACLC(충전 LED)는 시각 검증이라 자동 판정이 어려워 **점검 대상에서 제외**(UI에서 "수동 확인" 안내).
//

import Foundation

/// 점검 단계 — 자동 판정 가능한 제어 기능. (LED 등 시각 검증 항목은 제외.)
public enum SelfTestStep: String, Sendable, CaseIterable, Equatable {
    /// 충전 억제(CHTE) — 적용 후 충전이 멈춰야 한다. 충전 제어의 **기반**.
    case chargeInhibit
    /// 강제 방전/어댑터 차단(CHIE→CH0J→CH0I) — AC인데 배터리가 방전돼야 한다.
    case adapterDisable

    /// 효과검증에 쓸 제어 의도로 매핑.
    public var intent: ControlIntent {
        switch self {
        case .chargeInhibit:  return .chargeInhibited
        case .adapterDisable: return .adapterDisabled
        }
    }

    /// 이 단계가 검증하는 제어 능력.
    public var capability: ControlCapability { ControlCapability(intent: intent) }

    /// UI 표시용 한국어 라벨.
    public var label: String {
        switch self {
        case .chargeInhibit:  return "충전 억제"
        case .adapterDisable: return "강제 방전(어댑터 차단)"
        }
    }
}

/// 단계 판정 결과.
public enum SelfTestOutcome: Sendable, Equatable {
    /// 동작함 — 기대 거동이 관찰됨.
    case working
    /// 동작 안 함 — write됐는데 거동이 안 바뀜.
    case notWorking
    /// 판정 불가 — 전제 미충족/데이터 부족 등(사유 동반). 강등·승격에 쓰지 않는다.
    case undetermined(reason: String)
}

/// 한 단계의 (단계, 결과) 쌍.
public struct SelfTestStepResult: Sendable, Equatable, Identifiable {
    public let step: SelfTestStep
    public let outcome: SelfTestOutcome
    public var id: String { step.rawValue }
    public init(step: SelfTestStep, outcome: SelfTestOutcome) {
        self.step = step
        self.outcome = outcome
    }
}

public enum SelfTest {

    /// **전제조건 검사(순수)**. 단계 적용 *전*에 적용 직전 reading으로 판정 가능 여부를 확인한다.
    /// 불가하면 사유를 담은 `.undetermined`를 반환(→ 그 단계는 SMC를 건드리지 않고 건너뛴다). 가능하면 nil.
    ///
    /// 두 단계 모두 **어댑터(AC) 연결**이 있어야 "충전 멈춤/방전 방향"을 관찰할 수 있다(미충족 시 어댑터 필요).
    /// - chargeInhibit: 적용 직전 **충전 중**이어야 멈춤을 관찰할 수 있다(상한 도달 등으로 충전 아니면 판정 불가).
    /// - adapterDisable: 적용 직전 **방전 중이 아니어야** 차단 효과(방전 전환)를 관찰할 수 있다.
    public static func precondition(step: SelfTestStep, reading: BatteryReading) -> SelfTestOutcome? {
        guard reading.isACPresent else { return .undetermined(reason: "어댑터 필요") }
        switch step {
        case .chargeInhibit:
            if !ControlEffectVerifier.isChargingNow(reading) {
                return .undetermined(reason: "충전 중이 아님 — 상한 아래에서 충전 중일 때 점검")
            }
        case .adapterDisable:
            if ControlEffectVerifier.isDischargingNow(reading) {
                return .undetermined(reason: "이미 방전 중 — 관찰 불가")
            }
        }
        return nil
    }

    /// 거동 판정(ControlEffect) → 점검 결과 매핑(순수).
    public static func outcome(from effect: ControlEffect) -> SelfTestOutcome {
        switch effect {
        case .observed:     return .working
        case .notObserved:  return .notWorking
        case .inconclusive: return .undetermined(reason: "거동 변화를 충분히 관찰하지 못함")
        }
    }

    /// before(적용 직전) + after(정착 후 샘플)로 한 단계 결과를 판정(순수).
    /// 전제 미충족이면 사유 동반 `.undetermined`, 충족이면 거동 판정 결과를 매핑해 반환한다.
    /// (앱 계층은 전제 통과 시에만 SMC를 적용하므로 보통 precondition→apply→outcome 순으로 쓰지만,
    ///  이 함수는 전제+판정을 한 번에 묶어 테스트/오프라인 판정에 쓰기 위한 편의다.)
    public static func evaluate(
        step: SelfTestStep,
        before: BatteryReading,
        after: [BatteryReading],
        policy: EffectSamplingPolicy = .default
    ) -> SelfTestOutcome {
        if let pre = precondition(step: step, reading: before) { return pre }
        let effect = ControlEffectVerifier.judge(intent: step.intent, before: before, after: after, policy: policy)
        return outcome(from: effect)
    }

    /// 점검 결과들을 **능력별 효과 상태**에 반영(순수).
    /// - working → 그 능력 effective, notWorking → ineffective(사유), undetermined → 변경 없음.
    /// 능력별이므로 **충전 억제만 실패하면 그 능력 의존 기능만** 가려지고, 어댑터 차단이 동작하면
    /// 강제 방전은 유지된다(그 반대도). 어느 능력 실패가 다른 능력을 끄지 않는다.
    public static func resolvedCapabilities(
        base: ControlCapabilityState,
        results: [SelfTestStepResult]
    ) -> ControlCapabilityState {
        var state = base
        for r in results {
            switch r.outcome {
            case .working:
                state = state.setting(r.step.capability, .effective)
            case .notWorking:
                state = state.setting(r.step.capability, .ineffective(reason: "\(r.step.label) 미반영(점검)"))
            case .undetermined:
                break   // 불확실 → 변경 없음(강등/승격 안 함).
            }
        }
        return state
    }

    /// 점검 결과로 DeviceSupport **검증상태 승격**(순수). 강등은 능력별(resolvedCapabilities)에서 처리하므로
    /// 여기선 승격만: 모든 단계가 동작함(실패·판정불가 전무)이면 `mappedUnverified`→`verifiedOnHardware`.
    /// - 그 외/실패/불확실 → 변경 없음. base가 supported가 아니면 그대로.
    public static func resolvedSupport(
        base: DeviceSupportResult,
        results: [SelfTestStepResult]
    ) -> DeviceSupportResult {
        guard case .supported = base else { return base }
        if !results.isEmpty, results.allSatisfy({ $0.outcome == .working }) {
            return base.promotedToVerified()
        }
        return base
    }
}
