//
//  ChargePolicyEngine.swift
//  VoltaCore
//
//  순수 함수 기반 상태머신. 입력(현재 reading + 정책 + 직전 상태)으로 다음 상태를 결정한다.
//  부수효과 없음 → 단위 테스트가 쉽고, 앱/헬퍼 어디서든 동일하게 판단할 수 있다.
//
//  충전 제한(단일 상한): SoC<limit면 limit까지 충전, SoC≥limit면 유지(충전 억제, 능동 방전 없음).
//  재충전 하한(밴드 min)·히스테리시스 없음 — AC 재연결 시 SoC<limit면 매번 limit까지 충전한다.
//

import Foundation

public struct ChargePolicyEngine: Sendable {

    public init() {}

    /// 정책 판단 입력.
    public struct Input: Sendable {
        public var reading: BatteryReading
        public var policy: HelperPolicy
        public var previous: ChargeState

        public init(reading: BatteryReading, policy: HelperPolicy, previous: ChargeState) {
            self.reading = reading
            self.policy = policy
            self.previous = previous
        }
    }

    /// 다음 상태를 계산한다.
    public func evaluate(_ input: Input) -> ChargeState {
        let r = input.reading
        let p = input.policy

        // 0) 충전 비율을 알 수 없으면 대기.
        guard let charge = effectiveChargePercent(r) else { return .suspended }

        // 우선순위(안전 최우선): 과열 보호 > {외출 준비 XOR 강제 방전} > 기본 밴드. (docs/charge-policy.md §3-2/§4)

        // 1) 과열 보호(최우선) — 기능이 켜져 있고 "발열원이 동작 중"일 때 과열이면 모두 중단하고 식힌다.
        //    발열원 = 충전(=AC 연결) 또는 강제 방전(능동 방전). 외출 준비도 AC 충전이라 isACPresent로 포함된다.
        //    → heatPaused는 충전·강제 방전·외출 준비를 모두 멈추는 유지(idle) 상태. 식으면 아래 규칙으로 복귀.
        let forceDischargeActive = p.forceDischargeTarget.map { charge > $0 } ?? false
        if let ceiling = p.heatProtectionCeiling,
           let temp = r.temperatureCelsius,
           temp >= ceiling,
           r.isACPresent || forceDischargeActive {
            return .heatPaused
        }

        // 2) 사용자 강제 방전(옵트인, 기능 3) — 외출 준비와 상호 배타(정책 검증에서 보장).
        if forceDischargeActive {
            return .forcedDischarge
        }

        // 3) 외출 준비(수동 100% 오버라이드) — AC 연결 시 충전 제한을 무시하고 100%까지 충전.
        if p.tripPrepEnabled, r.isACPresent, charge < 100 {
            return .charging
        }

        // 4) 외부 전원 미연결 → 배터리 사용(충전 제한 비적용).
        guard r.isACPresent else { return .discharging }

        // 5) 충전 제한(단일 상한): SoC<limit → limit까지 충전 / SoC≥limit → 유지(충전 억제, 능동 방전 없음).
        return charge < p.chargeLimit ? .charging : .limitReached
    }

    /// 정책 판단에 쓸 충전 비율. 하드웨어 비율이 있으면 우선, 없으면 OS 비율.
    public func effectiveChargePercent(_ r: BatteryReading) -> Int? {
        if let hw = r.hardwareChargePercent {
            return Int(hw.rounded())
        }
        return r.osChargePercent
    }

    /// 강제 방전이 1회성으로 "완료"됐는지(SoC ≤ 목표). 완료면 호출측이 forceDischargeTarget을
    /// 해제(off)해 충전 제한 정책으로 복귀시킨다 → 전력 연결 시 max까지 충전. (해제하지 않으면
    /// max까지 충전 후 다시 목표까지 방전하는 무한 루프가 생기므로 1회성으로 끊는다.)
    /// AC 연결 여부와 무관 — 전력이 끊겨 자연 방전으로 목표 이하가 된 경우에도 완료로 본다.
    public func isForceDischargeComplete(reading r: BatteryReading, policy p: HelperPolicy) -> Bool {
        guard let target = p.forceDischargeTarget, let charge = effectiveChargePercent(r) else { return false }
        return charge <= target
    }

    /// 기능 5(기본 동작): 강제 방전/외출 준비가 "목표 도달 전" 작동 중이면 시스템 수면을 자동 방지해야 한다.
    /// - 강제 방전: forceDischargeTarget이 살아 있으면 미도달(도달 시 호출측이 해제) → 방지.
    /// - 외출 준비: SoC < 100%면 미도달 → 방지(SoC 미상이면 안전하게 방지).
    /// 둘 다 비활성이면 false. (충전 중 수면 방지(기능 7)와는 별개 경로로 합산된다.)
    public func shouldPreventSleepForOverride(reading r: BatteryReading, policy p: HelperPolicy) -> Bool {
        if p.forceDischargeTarget != nil { return true }
        if p.tripPrepEnabled, (effectiveChargePercent(r) ?? 0) < 100 { return true }
        return false
    }
}
