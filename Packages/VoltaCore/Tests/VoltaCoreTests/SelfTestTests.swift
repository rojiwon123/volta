//
//  SelfTestTests.swift
//  VoltaCoreTests
//
//  점검(self-test) 순수 로직 단위 테스트. reading은 목킹(실제 SMC 효과는 서명 헬퍼·실기에서만 확정).
//  전제조건·거동→결과 매핑·DeviceSupport 반영(강등/승격)을 검증한다.
//

import Testing
@testable import VoltaCore

@Suite struct SelfTestTests {

    private func r(charging: Bool, ac: Bool, batteryW: Double) -> BatteryReading {
        BatteryReading(isCharging: charging, isACPresent: ac, power: .init(batteryWatts: batteryW))
    }

    // MARK: 전제조건

    @Test func bothStepsNeedAdapter() {
        let noAC = r(charging: false, ac: false, batteryW: -8)
        #expect(SelfTest.precondition(step: .chargeInhibit, reading: noAC) == .undetermined(reason: "어댑터 필요"))
        #expect(SelfTest.precondition(step: .adapterDisable, reading: noAC) == .undetermined(reason: "어댑터 필요"))
    }

    @Test func chargeInhibitNeedsChargingBefore() {
        // AC인데 충전 아님(상한 도달 등) → 멈춤을 관찰할 수 없어 판정 불가.
        let holding = r(charging: false, ac: true, batteryW: 0)
        if case .undetermined = SelfTest.precondition(step: .chargeInhibit, reading: holding) {} else {
            Issue.record("충전 아님이면 판정 불가여야 함")
        }
        // AC + 충전 중 → 진행 가능(nil).
        let charging = r(charging: true, ac: true, batteryW: 12)
        #expect(SelfTest.precondition(step: .chargeInhibit, reading: charging) == nil)
    }

    @Test func adapterDisableNeedsNotDischargingBefore() {
        // AC인데 이미 방전 중 → 관찰 불가.
        let draining = r(charging: false, ac: true, batteryW: -10)
        if case .undetermined = SelfTest.precondition(step: .adapterDisable, reading: draining) {} else {
            Issue.record("이미 방전 중이면 판정 불가여야 함")
        }
        // AC + 유지(0W) → 진행 가능.
        let holding = r(charging: false, ac: true, batteryW: 0)
        #expect(SelfTest.precondition(step: .adapterDisable, reading: holding) == nil)
    }

    // MARK: 거동 → 결과 매핑

    @Test func effectMapsToOutcome() {
        #expect(SelfTest.outcome(from: .observed) == .working)
        #expect(SelfTest.outcome(from: .notObserved) == .notWorking)
        if case .undetermined = SelfTest.outcome(from: .inconclusive) {} else {
            Issue.record("inconclusive는 판정 불가로 매핑돼야 함")
        }
    }

    // MARK: evaluate (전제 + 거동 판정 묶음)

    @Test func evaluateWorkingWhenChargingStops() {
        let before = r(charging: true, ac: true, batteryW: 12)
        let after = [r(charging: true, ac: true, batteryW: 12),
                     r(charging: false, ac: true, batteryW: 0),
                     r(charging: false, ac: true, batteryW: 0)]
        #expect(SelfTest.evaluate(step: .chargeInhibit, before: before, after: after) == .working)
    }

    @Test func evaluateNotWorkingWhenStillCharging() {
        let before = r(charging: true, ac: true, batteryW: 12)
        let after = [r(charging: true, ac: true, batteryW: 12),
                     r(charging: true, ac: true, batteryW: 11),
                     r(charging: true, ac: true, batteryW: 12)]
        #expect(SelfTest.evaluate(step: .chargeInhibit, before: before, after: after) == .notWorking)
    }

    @Test func evaluateUndeterminedWhenPreconditionFails() {
        // 어댑터 없음 → after가 무엇이든 전제에서 막혀 판정 불가.
        let before = r(charging: false, ac: false, batteryW: -8)
        let after = [r(charging: false, ac: false, batteryW: -8), r(charging: false, ac: false, batteryW: -9)]
        #expect(SelfTest.evaluate(step: .chargeInhibit, before: before, after: after) == .undetermined(reason: "어댑터 필요"))
    }

    @Test func evaluateAdapterDisableWorkingWhenDrains() {
        let before = r(charging: true, ac: true, batteryW: 8)
        let after = [r(charging: false, ac: true, batteryW: 2),
                     r(charging: false, ac: true, batteryW: -7),
                     r(charging: false, ac: true, batteryW: -8)]
        #expect(SelfTest.evaluate(step: .adapterDisable, before: before, after: after) == .working)
    }

    // MARK: 결과 → DeviceSupport 반영

    private func res(_ step: SelfTestStep, _ outcome: SelfTestOutcome) -> SelfTestStepResult {
        .init(step: step, outcome: outcome)
    }

    @Test func chargeInhibitFailureDowngradesToIneffective() {
        let base = DeviceSupportResult.supported(.mappedUnverified)
        let results = [res(.chargeInhibit, .notWorking), res(.adapterDisable, .working)]
        if case .ineffective = SelfTest.resolvedSupport(base: base, results: results) {} else {
            Issue.record("충전 억제 실패는 .ineffective로 강등돼야 함")
        }
    }

    @Test func allWorkingPromotesToVerified() {
        let base = DeviceSupportResult.supported(.mappedUnverified)
        let results = [res(.chargeInhibit, .working), res(.adapterDisable, .working)]
        #expect(SelfTest.resolvedSupport(base: base, results: results) == .supported(.verifiedOnHardware))
    }

    @Test func adapterFailAloneDoesNotDowngrade() {
        // 충전 억제는 동작, 강제 방전만 실패 → 전체를 끄지 않고 그대로 유지(보고로만 드러냄).
        let base = DeviceSupportResult.supported(.mappedUnverified)
        let results = [res(.chargeInhibit, .working), res(.adapterDisable, .notWorking)]
        #expect(SelfTest.resolvedSupport(base: base, results: results) == base)
    }

    @Test func undeterminedMixDoesNotPromoteOrDowngrade() {
        let base = DeviceSupportResult.supported(.mappedUnverified)
        let results = [res(.chargeInhibit, .working), res(.adapterDisable, .undetermined(reason: "어댑터 필요"))]
        #expect(SelfTest.resolvedSupport(base: base, results: results) == base)   // 불확실 → 변경 없음
    }

    @Test func unsupportedBaseUnchanged() {
        let base = DeviceSupportResult.unsupported(reason: "x")
        let results = [res(.chargeInhibit, .working), res(.adapterDisable, .working)]
        #expect(SelfTest.resolvedSupport(base: base, results: results) == base)
    }

    @Test func promotedToVerifiedOnlyFromMappedUnverified() {
        #expect(DeviceSupportResult.supported(.mappedUnverified).promotedToVerified() == .supported(.verifiedOnHardware))
        #expect(DeviceSupportResult.supported(.verifiedOnHardware).promotedToVerified() == .supported(.verifiedOnHardware))
        #expect(DeviceSupportResult.unsupported(reason: "x").promotedToVerified() == .unsupported(reason: "x"))
        #expect(DeviceSupportResult.ineffective(reason: "x").promotedToVerified() == .ineffective(reason: "x"))
    }

    @Test func emptyResultsDoNotPromote() {
        let base = DeviceSupportResult.supported(.mappedUnverified)
        #expect(SelfTest.resolvedSupport(base: base, results: []) == base)
    }
}
