//
//  ChargeAction.swift
//  VoltaCore
//
//  정책 엔진이 산출하는 "원하는 하드웨어 상태". 헬퍼가 이 의도를 SMC 쓰기로 실현한다.
//  앱 단계(Phase 1)에서는 계산만 하고 적용하지 않는다.
//

import Foundation

public struct ChargeAction: Sendable, Equatable {
    /// 배터리로의 충전을 허용할지(false면 충전 중단 = CHTE/Charging inhibit).
    public var allowCharging: Bool

    /// 어댑터 급전을 끊어 강제 방전할지(true면 adapter disable = CHIE/Adapter off, 기능 3).
    public var forceDischarge: Bool

    public init(allowCharging: Bool, forceDischarge: Bool) {
        self.allowCharging = allowCharging
        self.forceDischarge = forceDischarge
    }

    /// 안전 기본값: 충전 허용, 방전 안 함(= 시스템 기본 동작에 가장 가까움).
    public static let safeDefault = ChargeAction(allowCharging: true, forceDischarge: false)

    /// 상태에서 의도된 하드웨어 동작으로 매핑.
    public static func from(state: ChargeState) -> ChargeAction {
        switch state {
        case .charging:
            return ChargeAction(allowCharging: true, forceDischarge: false)
        case .limitReached, .heatPaused, .suspended:
            return ChargeAction(allowCharging: false, forceDischarge: false)
        case .discharging:
            // 전원 미연결: 하드웨어적으로 이미 방전. 충전 inhibit 유지로 재충전 방지.
            return ChargeAction(allowCharging: false, forceDischarge: false)
        case .forcedDischarge:
            return ChargeAction(allowCharging: false, forceDischarge: true)
        }
    }
}
