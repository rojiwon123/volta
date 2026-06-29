//
//  ChargeState.swift
//  VoltaCore
//
//  ChargePolicyEngine가 산출하는 충전 정책 상태.
//

import Foundation

public enum ChargeState: String, Sendable, CaseIterable, CustomStringConvertible {
    /// 상한 미만 + 전원 연결 → 정상 충전.
    case charging
    /// 상한 도달 → 충전 중단(어댑터 직접 급전, 배터리 유지).
    case limitReached
    /// 전원 미연결 → 배터리 사용.
    case discharging
    /// 사용자가 강제 방전을 요청해 의도적으로 배터리를 소모하는 중(기능 3).
    case forcedDischarge
    /// 과열 → 충전 일시정지(기능 5).
    case heatPaused
    /// 데이터 없음/비활성(초기/헬퍼 미연결 등).
    case suspended

    public var description: String { rawValue }

    /// 사용자에게 보여줄 한국어 라벨.
    public var localizedLabel: String {
        switch self {
        case .charging:        return "충전 중"
        case .limitReached:    return "제한 도달(유지)"
        case .discharging:     return "배터리 사용"
        case .forcedDischarge: return "강제 방전 중"
        case .heatPaused:      return "과열로 일시정지"
        case .suspended:       return "대기"
        }
    }
}
