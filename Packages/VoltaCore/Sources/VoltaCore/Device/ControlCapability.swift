//
//  ControlCapability.swift
//  VoltaCore
//
//  제어 "능력(capability)" 단위 모델. 기기 전체를 한 번에 켜고 끄는(allowsSMCWrites / 전체 .ineffective)
//  대신, 제어를 **능력별**로 구분해 효과검증·비활성화를 세분한다. 한 능력이 이 기기에서 안 먹어도
//  그 능력에 의존하는 기능만 가려지고, 다른 능력으로 동작하는 기능은 유지된다.
//
//  능력 ↔ SMC 키:
//   - chargeInhibit  : 충전 억제(CHTE) — 충전을 멈춘다.
//   - adapterDisable : 어댑터 차단/강제 방전(CHIE→CH0J→CH0I) — AC인데 배터리에서 빼낸다.
//
//  이 파일은 순수 모델/판정(단위 테스트). 효과 관찰·적용은 앱 계층(BatteryMonitor)이 한다.
//

import Foundation

/// 제어 능력(SMC 키 묶음) 단위.
public enum ControlCapability: String, Sendable, CaseIterable, Equatable {
    case chargeInhibit
    case adapterDisable

    /// 효과검증 의도 ↔ 능력 매핑.
    public init(intent: ControlIntent) {
        switch intent {
        case .chargeInhibited: self = .chargeInhibit
        case .adapterDisabled: self = .adapterDisable
        }
    }

    public var label: String {
        switch self {
        case .chargeInhibit:  return "충전 억제"
        case .adapterDisable: return "어댑터 차단(강제 방전)"
        }
    }
}

/// 제어 기능(사용자에게 보이는 단위) → 의존 능력. 한 기능은 한 능력에 의존한다.
public enum ControlFeature: String, Sendable, CaseIterable, Equatable {
    case chargeLimit       // 충전 제한 — 상한에서 멈추려면 충전 억제 필요.
    case heatProtection    // 과열 보호 — 고온 시 충전 중단(충전 억제).
    case sleepChargeStop   // 수면 중 충전 중단 — 수면 시 충전 억제.
    case sleepInhibit      // 상한까지 잠자기 억제 — 상한(충전 억제)이 동작해야 의미.
    case tripPrep          // 외출 준비 — 충전 제어(억제) 패밀리의 상한 오버라이드.
    case forceDischarge    // 강제 방전 — 어댑터 차단 필요.

    /// 이 기능이 실제로 의존하는 제어 능력.
    public var requiredCapability: ControlCapability {
        switch self {
        case .forceDischarge: return .adapterDisable
        default:              return .chargeInhibit
        }
    }

    public var label: String {
        switch self {
        case .chargeLimit:     return "충전 제한"
        case .heatProtection:  return "과열 보호"
        case .sleepChargeStop: return "수면 중 충전 중단"
        case .sleepInhibit:    return "상한까지 잠자기 억제"
        case .tripPrep:        return "외출 준비"
        case .forceDischarge:  return "강제 방전"
        }
    }
}

/// 한 능력의 런타임 효과 상태.
public enum CapabilityEffectiveness: Sendable, Equatable {
    /// 아직 검증 안 됨 — 정적 지원 상태대로 사용 가능(낙관적).
    case untested
    /// 효과 관찰됨(동작).
    case effective
    /// write됐는데 거동이 안 바뀜 → 이 능력 비활성(의존 기능 숨김).
    case ineffective(reason: String)
}

/// 능력별 효과 상태 묶음 + 판정(순수). 미기재 능력은 `.untested`로 본다.
public struct ControlCapabilityState: Sendable, Equatable {
    private var map: [ControlCapability: CapabilityEffectiveness]

    public init(_ map: [ControlCapability: CapabilityEffectiveness] = [:]) { self.map = map }

    public func effectiveness(_ cap: ControlCapability) -> CapabilityEffectiveness {
        map[cap] ?? .untested
    }

    /// 능력이 비활성(ineffective)인지.
    public func isIneffective(_ cap: ControlCapability) -> Bool {
        if case .ineffective = effectiveness(cap) { return true }
        return false
    }

    /// 비활성 사유(있으면).
    public func ineffectiveReason(_ cap: ControlCapability) -> String? {
        if case .ineffective(let reason) = effectiveness(cap) { return reason }
        return nil
    }

    /// 한 능력의 상태를 바꾼 새 값(순수).
    public func setting(_ cap: ControlCapability, _ e: CapabilityEffectiveness) -> ControlCapabilityState {
        var m = map
        m[cap] = e
        return ControlCapabilityState(m)
    }

    /// 효과검증 결과를 능력에 반영(순수).
    /// - observed → effective, notObserved → ineffective(사유), inconclusive → 변경 없음(불확실 보수).
    public func applyingControlEffect(_ effect: ControlEffect, capability: ControlCapability, reason: String) -> ControlCapabilityState {
        switch effect {
        case .observed:     return setting(capability, .effective)
        case .notObserved:  return setting(capability, .ineffective(reason: reason))
        case .inconclusive: return self
        }
    }

    /// 헬퍼 미연결이면 런타임 비활성(ineffective)을 `.untested`로 되돌린다(순수).
    /// 헬퍼가 없으면 write 자체가 안 일어나 "효과 미관찰"을 단정할 수 없으므로, 비활성을 유지하지 않는다.
    public func clearedIfWriteUnavailable(helperReachable: Bool) -> ControlCapabilityState {
        guard !helperReachable else { return self }
        var m = map
        for (k, v) in m {
            if case .ineffective = v { m[k] = .untested }
        }
        return ControlCapabilityState(m)
    }
}

/// 기능 노출 판정(순수). 기기 지원 + 헬퍼 연결 + 해당 능력이 비활성 아님일 때만 노출.
public enum ControlAvailability {

    /// 한 능력을 실제로 쓸 수 있는지: 기기 SMC 쓰기 가능 + 헬퍼 연결 + 그 능력 비활성 아님.
    public static func isCapabilityAvailable(
        _ cap: ControlCapability,
        deviceWritable: Bool,
        helperReachable: Bool,
        capabilities: ControlCapabilityState
    ) -> Bool {
        deviceWritable && helperReachable && !capabilities.isIneffective(cap)
    }

    /// 한 기능을 노출/사용할 수 있는지: 그 기능이 의존하는 능력이 사용 가능할 때.
    public static func isFeatureAvailable(
        _ feature: ControlFeature,
        deviceWritable: Bool,
        helperReachable: Bool,
        capabilities: ControlCapabilityState
    ) -> Bool {
        isCapabilityAvailable(feature.requiredCapability,
                              deviceWritable: deviceWritable,
                              helperReachable: helperReachable,
                              capabilities: capabilities)
    }

    /// 컨트롤 영역을 보일지: 능력 중 하나라도 사용 가능하면 true(전부 비활성이면 false → 플레이스홀더).
    public static func anyCapabilityAvailable(
        deviceWritable: Bool,
        helperReachable: Bool,
        capabilities: ControlCapabilityState
    ) -> Bool {
        ControlCapability.allCases.contains {
            isCapabilityAvailable($0, deviceWritable: deviceWritable, helperReachable: helperReachable, capabilities: capabilities)
        }
    }
}
