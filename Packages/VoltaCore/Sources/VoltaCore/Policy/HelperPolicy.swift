//
//  HelperPolicy.swift
//  VoltaCore
//
//  앱이 헬퍼에 "사전 푸시"하는 정책값(기능 8). 헬퍼는 sleep/wake 시 이 값으로
//  XPC 왕복 없이 즉시 SMC를 적용한다. JSON 직렬화로 XPC 경계를 넘긴다.
//

import Foundation

public struct HelperPolicy: Codable, Sendable, Equatable {
    /// 충전 제한(상한 %). 기능 1. **단일 상한 모델** — SoC<limit면 limit까지 충전, SoC≥limit면 유지(충전 억제).
    public var chargeLimit: Int

    /// 과열 보호 임계 온도(℃). 기능 5. nil이면 비활성.
    public var heatProtectionCeiling: Double?

    /// 사용자 강제 방전 목표(%). nil이면 비활성(기능 3).
    /// **외출 준비(tripPrepEnabled)와 상호 배타** — 둘 다 활성일 수 없다(validated에서 보장).
    public var forceDischargeTarget: Int?

    /// 외출 준비(수동 100% 풀충전 오버라이드). true면 충전 제한을 무시하고 100%까지 충전한다.
    /// 일시 오버라이드 — 해제하면 충전 제한 규칙으로 복귀. **강제 방전과 상호 배타**(둘 다 활성 불가).
    /// 과열 보호가 켜진 상태에서 과열이면 외출 준비도 중단된다(과열 최우선).
    public var tripPrepEnabled: Bool

    /// 수면 중 충전 허용 여부. **기본 false = 수면 시 충전 중단(현재 잔량 유지)** — 자는 동안 상한에서 못 멈추니 과충전 방지(기능 8).
    /// true(opt-in)면 수면 중에도 상한까지 충전 허용. 헬퍼는 sleep 직전 이 값이 false면 충전을 inhibit, wake 시 정책 재적용.
    public var allowChargingWhileAsleep: Bool

    /// 상한 도달까지 sleep 억제(IOPMAssertion) 사용 여부(기능 2).
    public var inhibitSleepUntilLimit: Bool

    public init(
        chargeLimit: Int = 80,
        heatProtectionCeiling: Double? = 40.0,
        forceDischargeTarget: Int? = nil,
        tripPrepEnabled: Bool = false,
        allowChargingWhileAsleep: Bool = false,
        inhibitSleepUntilLimit: Bool = false
    ) {
        self.chargeLimit = chargeLimit
        self.heatProtectionCeiling = heatProtectionCeiling
        self.forceDischargeTarget = forceDischargeTarget
        self.tripPrepEnabled = tripPrepEnabled
        self.allowChargingWhileAsleep = allowChargingWhileAsleep
        self.inhibitSleepUntilLimit = inhibitSleepUntilLimit
    }

    // 구버전 JSON 호환: 제거된 필드(chargeStartThreshold/dischargeFloor)는 키가 있어도 무시되고,
    // 누락 필드는 기본값으로 디코드(비옵션 전환 깨짐 방지). 인코딩은 합성.
    private enum CodingKeys: String, CodingKey {
        case chargeLimit
        case heatProtectionCeiling, forceDischargeTarget, tripPrepEnabled, allowChargingWhileAsleep, inhibitSleepUntilLimit
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        chargeLimit = try c.decode(Int.self, forKey: .chargeLimit)
        heatProtectionCeiling = try c.decodeIfPresent(Double.self, forKey: .heatProtectionCeiling)
        forceDischargeTarget = try c.decodeIfPresent(Int.self, forKey: .forceDischargeTarget)
        tripPrepEnabled = try c.decodeIfPresent(Bool.self, forKey: .tripPrepEnabled) ?? false
        allowChargingWhileAsleep = try c.decode(Bool.self, forKey: .allowChargingWhileAsleep)
        inhibitSleepUntilLimit = try c.decode(Bool.self, forKey: .inhibitSleepUntilLimit)
    }

    public static let `default` = HelperPolicy()

    // MARK: - 검증/클램프 (보안: 헬퍼는 앱이 보낸 값을 절대 무검증 사용 금지)

    /// 허용 범위.
    public enum Bounds {
        // AlDente 패리티: 충전 상한 20~100%(소프트웨어 충전-억제 방식이라 임의값 가능).
        public static let limit = 20...100
        public static let dischargeTarget = 10...95
        public static let ceiling = 30.0...60.0
    }

    /// 모든 필드를 안전 범위로 보정한 새 정책을 반환한다.
    /// (헬퍼 측에서 저장 전에 반드시 호출 — fail-safe 클램프.)
    public func validated() -> HelperPolicy {
        var p = self
        p.chargeLimit = min(max(chargeLimit, Bounds.limit.lowerBound), Bounds.limit.upperBound)
        if let t = forceDischargeTarget {
            p.forceDischargeTarget = min(max(t, Bounds.dischargeTarget.lowerBound), Bounds.dischargeTarget.upperBound)
        }
        if let c = heatProtectionCeiling {
            // NaN/무한 방어 + 범위 클램프.
            p.heatProtectionCeiling = c.isFinite
                ? min(max(c, Bounds.ceiling.lowerBound), Bounds.ceiling.upperBound)
                : nil
        }
        // 외출 준비 ↔ 강제 방전 상호 배타(fail-safe). UI가 이미 보장하지만, 둘 다 들어오면
        // 안전 우선으로 외출 준비(100% 강제 충전)를 끈다 — 묵시적 풀충전을 막는다.
        if p.tripPrepEnabled, p.forceDischargeTarget != nil {
            p.tripPrepEnabled = false
        }
        return p
    }

    /// 보정 없이 "유효한가"만 검사(거부 정책을 쓰고 싶을 때).
    public var isWithinBounds: Bool {
        guard Bounds.limit.contains(chargeLimit) else { return false }
        if let t = forceDischargeTarget, !Bounds.dischargeTarget.contains(t) { return false }
        if let c = heatProtectionCeiling, !(c.isFinite && Bounds.ceiling.contains(c)) { return false }
        if tripPrepEnabled, forceDischargeTarget != nil { return false }   // 상호 배타.
        return true
    }

    // MARK: - XPC 직렬화 헬퍼

    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    public static func decoded(from data: Data) throws -> HelperPolicy {
        try JSONDecoder().decode(HelperPolicy.self, from: data)
    }
}
