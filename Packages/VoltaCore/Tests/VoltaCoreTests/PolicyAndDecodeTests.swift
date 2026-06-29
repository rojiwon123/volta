//
//  PolicyAndDecodeTests.swift
//  VoltaCoreTests
//
//  순수 로직(상태머신 + 디코딩) 단위 테스트. 플랫폼 비의존이라 실기 없이도 검증 가능.
//  ⚠️ 이 환경엔 Swift 툴체인이 없어 실행은 못 함. 실기에서 `swift test`로 확인.
//

import Foundation
import Testing
@testable import VoltaCore

@Suite struct ChargePolicyEngineTests {
    let engine = ChargePolicyEngine()

    private func reading(charge: Int, ac: Bool, temp: Double? = nil) -> BatteryReading {
        BatteryReading(osChargePercent: charge, temperatureCelsius: temp, isACPresent: ac)
    }

    @Test func chargesBelowLimit() {
        let s = engine.evaluate(.init(
            reading: reading(charge: 50, ac: true),
            policy: .init(chargeLimit: 80),
            previous: .charging))
        #expect(s == .charging)
    }

    @Test func limitReachedAtOrAboveLimit() {
        let s = engine.evaluate(.init(
            reading: reading(charge: 80, ac: true),
            policy: .init(chargeLimit: 80),
            previous: .charging))
        #expect(s == .limitReached)
    }

    @Test func chargesJustBelowLimitNoHysteresis() {
        // 단일 상한: 직전이 유지였어도 SoC<limit면 다시 충전(히스테리시스 없음).
        let s = engine.evaluate(.init(
            reading: reading(charge: 78, ac: true),
            policy: .init(chargeLimit: 80),
            previous: .limitReached))
        #expect(s == .charging)
    }

    @Test func chargesWellBelowLimit() {
        // 재충전 하한 없음: limit 미만이면(예 55) 이전 상태 무관하게 충전.
        let s = engine.evaluate(.init(
            reading: reading(charge: 55, ac: true),
            policy: .init(chargeLimit: 80),
            previous: .limitReached))
        #expect(s == .charging)
    }

    @Test func dischargingWhenUnplugged() {
        let s = engine.evaluate(.init(
            reading: reading(charge: 60, ac: false),
            policy: .init(),
            previous: .charging))
        #expect(s == .discharging)
    }

    @Test func heatPausedWhenHotAndCharging() {
        let s = engine.evaluate(.init(
            reading: reading(charge: 50, ac: true, temp: 45),
            policy: .init(heatProtectionCeiling: 40),
            previous: .charging))
        #expect(s == .heatPaused)
    }

    @Test func forcedDischargeTakesPriority() {
        let s = engine.evaluate(.init(
            reading: reading(charge: 90, ac: true),
            policy: .init(forceDischargeTarget: 50),
            previous: .charging))
        #expect(s == .forcedDischarge)
    }

    @Test func suspendedWhenNoData() {
        let s = engine.evaluate(.init(
            reading: BatteryReading(),
            policy: .init(),
            previous: .charging))
        #expect(s == .suspended)
    }
}

@Suite struct ChargeActionTests {
    @Test func mappingCoversAllStates() {
        #expect(ChargeAction.from(state: .charging) == ChargeAction(allowCharging: true, forceDischarge: false))
        #expect(ChargeAction.from(state: .limitReached) == ChargeAction(allowCharging: false, forceDischarge: false))
        #expect(ChargeAction.from(state: .heatPaused) == ChargeAction(allowCharging: false, forceDischarge: false))
        #expect(ChargeAction.from(state: .discharging) == ChargeAction(allowCharging: false, forceDischarge: false))
        #expect(ChargeAction.from(state: .forcedDischarge) == ChargeAction(allowCharging: false, forceDischarge: true))
        #expect(ChargeAction.from(state: .suspended) == ChargeAction(allowCharging: false, forceDischarge: false))
    }
}

@Suite struct HelperPolicyValidationTests {
    @Test func clampsLimitIntoRange() {
        #expect(HelperPolicy(chargeLimit: 5).validated().chargeLimit == 20)
        #expect(HelperPolicy(chargeLimit: 200).validated().chargeLimit == 100)
    }
    @Test func clampsDischargeTarget() {
        #expect(HelperPolicy(forceDischargeTarget: 1).validated().forceDischargeTarget == 10)
        #expect(HelperPolicy(forceDischargeTarget: 99).validated().forceDischargeTarget == 95)
    }
    @Test func roundTripCodableSingleLimit() throws {
        let p = HelperPolicy(chargeLimit: 85)
        let back = try HelperPolicy.decoded(from: p.encoded())
        #expect(back == p)
        #expect(back.chargeLimit == 85)
    }
    @Test func rejectsNonFiniteCeiling() {
        #expect(HelperPolicy(heatProtectionCeiling: .nan).validated().heatProtectionCeiling == nil)
    }
    @Test func clampsCeiling() {
        #expect(HelperPolicy(heatProtectionCeiling: 10).validated().heatProtectionCeiling == 30)
        #expect(HelperPolicy(heatProtectionCeiling: 99).validated().heatProtectionCeiling == 60)
    }
    @Test func isWithinBoundsDetectsBad() {
        #expect(HelperPolicy(chargeLimit: 80).isWithinBounds)
        #expect(!HelperPolicy(chargeLimit: 10).isWithinBounds)          // 상한 범위 밖(20 미만)
        #expect(!HelperPolicy(chargeLimit: 80, forceDischargeTarget: 5).isWithinBounds)  // 목표 범위 밖
    }
    @Test func roundTripCodable() throws {
        let p = HelperPolicy(chargeLimit: 85, forceDischargeTarget: 40)
        let back = try HelperPolicy.decoded(from: p.encoded())
        #expect(back == p)
    }
    @Test func sleepHoldIsDefault() {
        // 수면 중 충전: 기본은 중단(현재 잔량 유지). false → 헬퍼가 sleep 직전 충전 inhibit.
        #expect(HelperPolicy().allowChargingWhileAsleep == false)
        #expect(HelperPolicy.default.allowChargingWhileAsleep == false)
    }
    @Test func sleepAllowOptInRoundTrips() throws {
        let back = try HelperPolicy.decoded(from: HelperPolicy(allowChargingWhileAsleep: true).encoded())
        #expect(back.allowChargingWhileAsleep == true)
    }
    @Test func decodesLegacyJSONIgnoringRemovedFields() throws {
        // 구버전 JSON(제거된 chargeStartThreshold/dischargeFloor 포함)도 안전하게 디코드 — 해당 키는 무시.
        let legacy = #"{"chargeLimit":80,"chargeStartThreshold":75,"dischargeFloor":60,"allowChargingWhileAsleep":false,"inhibitSleepUntilLimit":false}"#
        let p = try HelperPolicy.decoded(from: Data(legacy.utf8))
        #expect(p.chargeLimit == 80)
        #expect(p.tripPrepEnabled == false)
    }
    @Test func tripPrepDefaultsOffAndRoundTrips() throws {
        #expect(HelperPolicy().tripPrepEnabled == false)
        let back = try HelperPolicy.decoded(from: HelperPolicy(tripPrepEnabled: true).encoded())
        #expect(back.tripPrepEnabled == true)
    }
    @Test func tripPrepAndForceDischargeMutuallyExclusive() {
        // 둘 다 활성으로 들어오면 fail-safe로 외출 준비를 끈다(강제 방전 유지).
        let p = HelperPolicy(forceDischargeTarget: 50, tripPrepEnabled: true).validated()
        #expect(p.tripPrepEnabled == false)
        #expect(p.forceDischargeTarget == 50)
        // isWithinBounds는 둘 다 활성을 거부.
        #expect(!HelperPolicy(forceDischargeTarget: 50, tripPrepEnabled: true).isWithinBounds)
    }
}

@Suite struct EffectivePercentTests {
    let engine = ChargePolicyEngine()
    @Test func prefersHardwareWhenPresent() {
        let r = BatteryReading(osChargePercent: 90, hardwareChargePercent: 82.4)
        #expect(engine.effectiveChargePercent(r) == 82)   // rounded
    }
    @Test func fallsBackToOS() {
        let r = BatteryReading(osChargePercent: 77)
        #expect(engine.effectiveChargePercent(r) == 77)
    }
    @Test func nilWhenNoData() {
        #expect(engine.effectiveChargePercent(BatteryReading()) == nil)
    }
}

@Suite struct PolicyEdgeTests {
    let engine = ChargePolicyEngine()
    @Test func heatIgnoredWhenUnplugged() {
        // 과열이어도 전원 미연결이면 충전경로가 아니므로 discharging.
        let r = BatteryReading(osChargePercent: 50, temperatureCelsius: 50, isACPresent: false)
        #expect(engine.evaluate(.init(reading: r, policy: .init(heatProtectionCeiling: 40), previous: .charging)) == .discharging)
    }
    @Test func forceDischargeStopsAtTarget() {
        // 목표 이하로 내려오면 더 이상 forcedDischarge 아님.
        let r = BatteryReading(osChargePercent: 50, isACPresent: true)
        #expect(engine.evaluate(.init(reading: r, policy: .init(forceDischargeTarget: 50), previous: .forcedDischarge)) != .forcedDischarge)
    }
    @Test func belowLimitChargesRegardlessOfPrevious() {
        // 단일 상한: limit 미만이면 직전이 유지였어도 충전(재충전 하한 없음).
        let r = BatteryReading(osChargePercent: 60, isACPresent: true)
        #expect(engine.evaluate(.init(reading: r, policy: .init(chargeLimit: 80), previous: .limitReached)) == .charging)
    }
}

@Suite struct ChargeLimitTests {
    let engine = ChargePolicyEngine()
    private func reading(_ c: Int, ac: Bool = true, temp: Double? = nil) -> BatteryReading {
        BatteryReading(osChargePercent: c, temperatureCelsius: temp, isACPresent: ac)
    }
    private func limit(_ max: Int) -> HelperPolicy { .init(chargeLimit: max) }

    @Test func aboveLimitHolds() {
        // SoC > limit 여도 자동 방전 없이 유지(충전 제한은 forcedDischarge를 만들지 않음).
        #expect(engine.evaluate(.init(reading: reading(90), policy: limit(80), previous: .charging)) == .limitReached)
        #expect(engine.evaluate(.init(reading: reading(90), policy: limit(80), previous: .limitReached)) == .limitReached)
    }
    @Test func belowLimitCharges() {
        // SoC < limit → 충전. 직전 상태 무관(재충전 하한·히스테리시스 없음).
        #expect(engine.evaluate(.init(reading: reading(55), policy: limit(80), previous: .limitReached)) == .charging)
        #expect(engine.evaluate(.init(reading: reading(79), policy: limit(80), previous: .limitReached)) == .charging)
        #expect(engine.evaluate(.init(reading: reading(70), policy: limit(80), previous: .charging)) == .charging)
    }
    @Test func atLimitHolds() {
        // 정확히 상한이면 유지(충전 정지). 자동 방전 없음.
        #expect(engine.evaluate(.init(reading: reading(80), policy: limit(80), previous: .charging)) == .limitReached)
        #expect(engine.evaluate(.init(reading: reading(80), policy: limit(80), previous: .limitReached)) == .limitReached)
    }
    @Test func heatTakesPriorityOverLimit() {
        // 과열은 충전 제한보다 우선 → SoC>limit여도 강제 방전이 아니라 heatPaused.
        let p = HelperPolicy(chargeLimit: 80, heatProtectionCeiling: 40)
        #expect(engine.evaluate(.init(reading: reading(90, ac: true, temp: 45), policy: p, previous: .charging)) == .heatPaused)
    }
    @Test func unpluggedDischarges() {
        #expect(engine.evaluate(.init(reading: reading(90, ac: false), policy: limit(80), previous: .charging)) == .discharging)
    }
    @Test func manualForceDischargeOverridesLimitHold() {
        // SoC≥limit(유지)이라도 사용자 강제 방전 목표(기능 3)가 더 우선.
        let p = HelperPolicy(chargeLimit: 80, forceDischargeTarget: 50)
        #expect(engine.evaluate(.init(reading: reading(70), policy: p, previous: .limitReached)) == .forcedDischarge)
    }

    // MARK: 오버라이드 우선순위(확정) — 과열 > {외출 준비 XOR 강제 방전} > 충전 제한.

    @Test func heatStopsForceDischargeOnAC() {
        // 강제 방전이 활성이어도 과열이면 heatPaused(과열 최우선). 발열원=강제 방전 중단.
        let p = HelperPolicy(chargeLimit: 80, heatProtectionCeiling: 40, forceDischargeTarget: 50)
        #expect(engine.evaluate(.init(reading: reading(90, ac: true, temp: 45), policy: p, previous: .forcedDischarge)) == .heatPaused)
    }
    @Test func heatStopsForceDischargeEvenWhenAdapterCut() {
        // 강제 방전 중엔 어댑터가 끊겨 AC가 false로 읽힐 수 있음 → 그래도 과열이면 중단(forceDischargeActive 경로).
        let p = HelperPolicy(chargeLimit: 80, heatProtectionCeiling: 40, forceDischargeTarget: 50)
        #expect(engine.evaluate(.init(reading: reading(90, ac: false, temp: 45), policy: p, previous: .forcedDischarge)) == .heatPaused)
    }
    @Test func forceDischargeStillRunsWhenNotHot() {
        // 과열 보호가 켜져 있어도 온도가 임계 미만이면 강제 방전 정상 동작.
        let p = HelperPolicy(chargeLimit: 80, heatProtectionCeiling: 40, forceDischargeTarget: 50)
        #expect(engine.evaluate(.init(reading: reading(90, ac: true, temp: 30), policy: p, previous: .forcedDischarge)) == .forcedDischarge)
    }
    @Test func tripPrepChargesAboveLimit() {
        // 외출 준비: 충전 제한(80)을 무시하고 100%까지 충전 → SoC>limit여도 charging.
        let p = HelperPolicy(chargeLimit: 80, tripPrepEnabled: true)
        #expect(engine.evaluate(.init(reading: reading(85), policy: p, previous: .limitReached)) == .charging)
    }
    @Test func tripPrepHoldsAt100() {
        // 100% 도달 시 유지(더 충전 안 함).
        let p = HelperPolicy(chargeLimit: 80, tripPrepEnabled: true)
        #expect(engine.evaluate(.init(reading: reading(100), policy: p, previous: .charging)) == .limitReached)
    }
    @Test func tripPrepNeedsAC() {
        // AC 미연결이면 외출 준비여도 충전 불가 → 방전(충전 제한 비적용과 동일).
        let p = HelperPolicy(chargeLimit: 80, tripPrepEnabled: true)
        #expect(engine.evaluate(.init(reading: reading(85, ac: false), policy: p, previous: .charging)) == .discharging)
    }
    @Test func heatStopsTripPrep() {
        // 과열이면 외출 준비(100% 충전)도 중단(과열 최우선).
        let p = HelperPolicy(chargeLimit: 80, heatProtectionCeiling: 40, tripPrepEnabled: true)
        #expect(engine.evaluate(.init(reading: reading(85, ac: true, temp: 45), policy: p, previous: .charging)) == .heatPaused)
    }
    @Test func defaultPolicyChargesBelowLimit() {
        // 기본 정책(상한 80)에서 SoC<80이면 충전.
        #expect(engine.evaluate(.init(reading: reading(50), policy: .init(), previous: .limitReached)) == .charging)
    }
}

@Suite struct ForceDischargeCompletionTests {
    let engine = ChargePolicyEngine()
    private func reading(_ c: Int?, ac: Bool = true) -> BatteryReading {
        BatteryReading(osChargePercent: c, isACPresent: ac)
    }

    // MARK: 1회성 완료 판정 — 호출측(BatteryMonitor)이 이걸로 forceDischargeTarget을 해제(off)한다.

    @Test func notCompleteAboveTarget() {
        #expect(engine.isForceDischargeComplete(reading: reading(60), policy: .init(forceDischargeTarget: 50)) == false)
    }
    @Test func completeAtTarget() {
        #expect(engine.isForceDischargeComplete(reading: reading(50), policy: .init(forceDischargeTarget: 50)) == true)
    }
    @Test func completeBelowTargetFromNaturalDischarge() {
        // 전력 끊겨 자연 방전으로 목표 이하가 된 경우(AC 미연결 포함)도 완료.
        #expect(engine.isForceDischargeComplete(reading: reading(45, ac: false), policy: .init(forceDischargeTarget: 50)) == true)
    }
    @Test func notCompleteWhenInactiveOrNoData() {
        #expect(engine.isForceDischargeComplete(reading: reading(40), policy: .init(forceDischargeTarget: nil)) == false)
        #expect(engine.isForceDischargeComplete(reading: reading(nil), policy: .init(forceDischargeTarget: 50)) == false)
    }

    // MARK: 완료 후 동작 — 자동 해제로 target=nil이 되면 충전 제한 정책으로 복귀해 max까지 충전.

    @Test func afterCompletionChargesToLimitWhenPowered() {
        // 자동 해제(target nil) 후: 전력 연결 & SoC<max → 충전(=충전 모드 전환).
        #expect(engine.evaluate(.init(reading: reading(50), policy: .init(chargeLimit: 80, forceDischargeTarget: nil), previous: .forcedDischarge)) == .charging)
    }
    @Test func stillDischargingAboveTargetBeforeCompletion() {
        // 완료 전(SoC>목표)에는 계속 forcedDischarge.
        #expect(engine.evaluate(.init(reading: reading(70), policy: .init(forceDischargeTarget: 50), previous: .forcedDischarge)) == .forcedDischarge)
    }

    // MARK: 기능 5 — 강제 방전/외출 준비 작동 중 수면 자동 방지(목표 도달 전).

    @Test func sleepPreventedWhileForceDischarging() {
        #expect(engine.shouldPreventSleepForOverride(reading: reading(70), policy: .init(forceDischargeTarget: 50)) == true)
    }
    @Test func sleepPreventedWhileTripPrepBelow100() {
        #expect(engine.shouldPreventSleepForOverride(reading: reading(80), policy: .init(tripPrepEnabled: true)) == true)
    }
    @Test func sleepNotPreventedWhenTripPrepAt100() {
        #expect(engine.shouldPreventSleepForOverride(reading: reading(100), policy: .init(tripPrepEnabled: true)) == false)
    }
    @Test func sleepNotPreventedWhenNoOverride() {
        #expect(engine.shouldPreventSleepForOverride(reading: reading(60), policy: .init()) == false)
    }
}

@Suite struct DeviceSupportTests {
    private func info(arch: String = "arm64", arm64: Bool = true, model: String) -> DeviceInfo {
        DeviceInfo(architecture: arch, isAppleSilicon: arm64, modelIdentifier: model, osVersion: "26.5.1")
    }

    @Test func registeredAppleSiliconModelIsSupported() {
        // 현재 이 맥(Mac17,5)은 allowlist 등록 → 지원(검증 상태는 mappedUnverified).
        #expect(DeviceSupport.evaluate(info(model: "Mac17,5")) == .supported(.mappedUnverified))
    }
    @Test func intelIsUnsupported() {
        let r = DeviceSupport.evaluate(info(arch: "x86_64", arm64: false, model: "MacBookPro15,1"))
        #expect(r.allowsSMCWrites == false)
        if case .unsupported = r {} else { Issue.record("Intel은 미지원이어야 함") }
    }
    @Test func unregisteredAppleSiliconModelIsUnsupported() {
        // arm64여도 allowlist 미등록 모델이면 fail-safe로 미지원.
        let r = DeviceSupport.evaluate(info(model: "Mac99,9"))
        #expect(r.allowsSMCWrites == false)
    }
    @Test func unsupportedBlocksWrites() {
        #expect(DeviceSupportResult.unsupported(reason: "x").allowsSMCWrites == false)
        #expect(DeviceSupportResult.supported(.mappedUnverified).allowsSMCWrites == true)
    }
    @Test func currentMachineDetectionIsAppleSilicon() {
        // 이 테스트가 도는 기기(Apple Silicon)에서 탐지값 sanity.
        let cur = DeviceInfo.current
        #expect(cur.isAppleSilicon == true)
        #expect(cur.modelIdentifier.isEmpty == false)
        #expect(cur.architecture == "arm64")
    }
}

@Suite struct ClientRequirementTests {
    // 순수 요구문자열 빌더만 검증한다. 실제 SecCode 서명 검증은 "서명된 빌드 런타임"에서만 가능하므로
    // currentTeamIdentifier()/clientCodeSigningRequirement(런타임 파생)는 여기서 단정하지 않는다.

    @Test func buildsRequirementWithAnchorBundleAndTeam() {
        let r = HelperConstants.makeClientRequirement(team: "ABCDE12345")
        #expect(r != nil)
        let req = r ?? ""
        #expect(req.contains("anchor apple generic"))                       // Apple anchor
        #expect(req.contains("identifier \"com.rojiwon.volta\""))           // 기대 번들 ID 핀
        #expect(req.contains("certificate leaf[subject.OU] = \"ABCDE12345\""))  // 팀 일치
    }
    @Test func nilTeamIsFailClosed() {
        // 자기 팀을 못 읽으면 nil → HelperListener가 모든 연결 거부.
        #expect(HelperConstants.makeClientRequirement(team: nil) == nil)
    }
    @Test func emptyTeamIsFailClosed() {
        // 빈 OU 요구(subject.OU = "")로 무서명 연결을 통과시키지 않는다.
        #expect(HelperConstants.makeClientRequirement(team: "") == nil)
    }
    @Test func teamValueIsPinnedExactly() {
        // 다른 팀 값은 다른 요구문자열을 만든다(주입 검증).
        let a = HelperConstants.makeClientRequirement(team: "AAAA111111")
        let b = HelperConstants.makeClientRequirement(team: "BBBB222222")
        #expect(a != b)
        #expect(a?.contains("AAAA111111") == true)
    }
}

@Suite struct ControlEffectTests {
    // 거동 reading 목킹. 실제 SMC 효과는 서명된 헬퍼·실기에서만 확정(여기선 미검증).
    private func r(charging: Bool, ac: Bool, batteryW: Double) -> BatteryReading {
        BatteryReading(isCharging: charging, isACPresent: ac, power: .init(batteryWatts: batteryW))
    }

    // (a) 효과 관찰됨 → observed (강등 안 함).
    @Test func chargeInhibitObservedWhenChargingStops() {
        // 적용 직전 충전 중 → 이후 멈춤(0W) = 억제 먹음.
        let before = r(charging: true, ac: true, batteryW: 12)
        let after = [r(charging: true, ac: true, batteryW: 12), r(charging: false, ac: true, batteryW: 0), r(charging: false, ac: true, batteryW: 0)]
        #expect(ControlEffectVerifier.judge(intent: .chargeInhibited, before: before, after: after) == .observed)
    }
    @Test func adapterDisableObservedWhenBatteryDrains() {
        // AC인데 충전이었다가 → 이후 방전(-) = 차단 먹음.
        let before = r(charging: true, ac: true, batteryW: 10)
        let after = [r(charging: false, ac: true, batteryW: 5), r(charging: false, ac: true, batteryW: -8), r(charging: false, ac: true, batteryW: -9)]
        #expect(ControlEffectVerifier.judge(intent: .adapterDisabled, before: before, after: after) == .observed)
    }

    // (b) 효과 미관찰 → notObserved → 강등 경로.
    @Test func chargeInhibitNotObservedWhenStillCharging() {
        let before = r(charging: true, ac: true, batteryW: 12)
        let after = [r(charging: true, ac: true, batteryW: 12), r(charging: true, ac: true, batteryW: 11), r(charging: true, ac: true, batteryW: 12)]
        #expect(ControlEffectVerifier.judge(intent: .chargeInhibited, before: before, after: after) == .notObserved)
    }
    @Test func adapterDisableNotObservedWhenStillCharging() {
        let before = r(charging: true, ac: true, batteryW: 10)
        let after = [r(charging: true, ac: true, batteryW: 10), r(charging: true, ac: true, batteryW: 9), r(charging: true, ac: true, batteryW: 10)]
        #expect(ControlEffectVerifier.judge(intent: .adapterDisabled, before: before, after: after) == .notObserved)
    }
    @Test func notObservedDowngradesSupport() {
        let s = DeviceSupportResult.supported(.mappedUnverified)
        #expect(s.applyingControlEffect(.notObserved, reason: "x") == .ineffective(reason: "x"))
        #expect(DeviceSupportResult.ineffective(reason: "x").allowsSMCWrites == false)
    }
    @Test func observedAndInconclusiveDoNotDowngrade() {
        let s = DeviceSupportResult.supported(.mappedUnverified)
        #expect(s.applyingControlEffect(.observed, reason: "x") == s)
        #expect(s.applyingControlEffect(.inconclusive, reason: "x") == s)
    }

    // (c) 정착 지연/샘플링 타이밍 — 결정 샘플 부족하면 inconclusive(즉시 판정 금지).
    @Test func inconclusiveWhenTooFewSamplesAfterSettle() {
        let before = r(charging: true, ac: true, batteryW: 12)
        // settleSamples=1 버리면 결정 샘플 1개 < min 2 → inconclusive.
        let after = [r(charging: false, ac: true, batteryW: 0), r(charging: false, ac: true, batteryW: 0)]
        #expect(ControlEffectVerifier.judge(intent: .chargeInhibited, before: before, after: after) == .inconclusive)
    }
    @Test func settleSamplesDiscardEarlyReadings() {
        // 첫 샘플은 아직 충전(정착 전) but 버려짐 → 이후 멈춤만 보고 observed.
        let before = r(charging: true, ac: true, batteryW: 12)
        let after = [r(charging: true, ac: true, batteryW: 12), r(charging: false, ac: true, batteryW: 0), r(charging: false, ac: true, batteryW: 0)]
        let policy = EffectSamplingPolicy(settleSamples: 1, minDecisiveSamples: 2)
        #expect(ControlEffectVerifier.judge(intent: .chargeInhibited, before: before, after: after, policy: policy) == .observed)
    }

    // 검증 의미 없는 조건 → inconclusive(강등 방지).
    @Test func inconclusiveWhenBeforeNotChargingForInhibit() {
        let before = r(charging: false, ac: true, batteryW: 0)   // 애초에 충전 아님
        let after = [r(charging: false, ac: true, batteryW: 0), r(charging: false, ac: true, batteryW: 0), r(charging: false, ac: true, batteryW: 0)]
        #expect(ControlEffectVerifier.judge(intent: .chargeInhibited, before: before, after: after) == .inconclusive)
    }

    // ★ 회귀(false negative 버그): 상한 도달/유지 상태에서 OS isCharging 플래그가 true여도 **실전류 ~0**이면
    // '실제 충전 아님' → 멈출 충전이 없으니 inconclusive여야 한다(notObserved로 잘못 강등 금지).
    @Test func inconclusiveWhenHoldingAtLimitDespiteChargingFlag() {
        let before = r(charging: true, ac: true, batteryW: 0)    // 플래그 true지만 watts≈0 = 유지
        let after = [r(charging: true, ac: true, batteryW: 0),
                     r(charging: true, ac: true, batteryW: 0),
                     r(charging: true, ac: true, batteryW: 0)]
        #expect(ControlEffectVerifier.judge(intent: .chargeInhibited, before: before, after: after) == .inconclusive)
    }
    // 실측 전력 우선: watts 양수면 충전, ~0이면 유지(플래그 무시). nil이면 플래그 폴백.
    @Test func isChargingNowUsesActualWattsOverFlag() {
        #expect(ControlEffectVerifier.isChargingNow(r(charging: true, ac: true, batteryW: 0)) == false)   // 유지
        #expect(ControlEffectVerifier.isChargingNow(r(charging: false, ac: true, batteryW: 8)) == true)   // 실충전
        #expect(ControlEffectVerifier.isChargingNow(BatteryReading(isCharging: true, isACPresent: true)) == true)  // watts nil → 플래그 폴백
    }
    // 전제조건 사유(진단/로그): 직전 충전 아님 → 사유 반환, 충전 중 → nil.
    @Test func preconditionReasonForInhibit() {
        #expect(ControlEffectVerifier.preconditionFailureReason(intent: .chargeInhibited, before: r(charging: true, ac: true, batteryW: 0)) != nil)
        #expect(ControlEffectVerifier.preconditionFailureReason(intent: .chargeInhibited, before: r(charging: true, ac: true, batteryW: 9)) == nil)
        #expect(ControlEffectVerifier.preconditionFailureReason(intent: .adapterDisabled, before: r(charging: false, ac: false, batteryW: -5)) == "AC 미연결")
    }
    @Test func inconclusiveWhenUnpluggedForAdapterDisable() {
        let before = r(charging: false, ac: false, batteryW: -8)  // 이미 방전(언플러그)
        let after = [r(charging: false, ac: false, batteryW: -8), r(charging: false, ac: false, batteryW: -9), r(charging: false, ac: false, batteryW: -8)]
        #expect(ControlEffectVerifier.judge(intent: .adapterDisabled, before: before, after: after) == .inconclusive)
    }

    // (a) 헬퍼 미연결/​write 미수행 → 효과검증 트리거 안 함(→ 강등 안 함, 오탐 방지).
    @Test func doesNotVerifyWhenWriteNotPerformed() {
        #expect(ControlEffectVerifier.shouldVerify(writePerformed: false, controlSupported: true) == false)
        #expect(ControlEffectVerifier.shouldVerify(writePerformed: false, controlSupported: false) == false)
    }
    @Test func verifiesOnlyWhenWritePerformedAndSupported() {
        #expect(ControlEffectVerifier.shouldVerify(writePerformed: true, controlSupported: true) == true)
        #expect(ControlEffectVerifier.shouldVerify(writePerformed: true, controlSupported: false) == false)
    }

    // (c) 헬퍼 없음(enabled 아님) 상태에서는 .ineffective가 표시/유지되지 않고 base로 복귀.
    @Test func ineffectiveClearedWhenHelperNotEnabled() {
        let base = DeviceSupportResult.supported(.mappedUnverified)
        let downgraded = DeviceSupportResult.ineffective(reason: "x")
        #expect(downgraded.clearedIfControlWriteUnavailable(helperEnabled: false, base: base) == base)   // 헬퍼 없음 → 해제
        #expect(downgraded.clearedIfControlWriteUnavailable(helperEnabled: true, base: base) == downgraded) // 헬퍼 있음 → 유지(진짜 케이스)
        // 강등이 아닌 상태는 헬퍼 유무와 무관하게 그대로.
        #expect(base.clearedIfControlWriteUnavailable(helperEnabled: false, base: base) == base)
    }
}

@Suite struct SMCKeySelectionTests {
    // probe 가용성 목킹. 실제 SMC 키 존재/효과는 서명된 root 헬퍼 실기에서만 확정(여기선 미검증).
    private func avail(_ codes: Set<String>) -> (SMCKey) -> Bool { { codes.contains($0.code) } }

    // (a) probe 기반 충전 억제 키 선택 — 없으면 nil(no-op).
    @Test func chargeInhibitSelectedOnlyWhenPresent() {
        #expect(SMCKeySelection.chargeInhibitKey(isAvailable: avail(["CHTE"]))?.code == "CHTE")
        #expect(SMCKeySelection.chargeInhibitKey(isAvailable: avail([])) == nil)
    }

    // (b) 어댑터 폴백 우선순위 CHIE → CH0J → CH0I, 없으면 비활성.
    @Test func adapterPrefersCHIEFirst() {
        #expect(SMCKeySelection.adapterKey(isAvailable: avail(["CHIE", "CH0J", "CH0I"]))?.key.code == "CHIE")
    }
    @Test func adapterFallsBackInOrder() {
        #expect(SMCKeySelection.adapterKey(isAvailable: avail(["CH0J", "CH0I"]))?.key.code == "CH0J")
        #expect(SMCKeySelection.adapterKey(isAvailable: avail(["CH0I"]))?.key.code == "CH0I")
    }
    @Test func adapterDisabledWhenNonePresent() {
        #expect(SMCKeySelection.adapterKey(isAvailable: avail([])) == nil)   // 셋 다 없음 → 강제 방전 비활성
    }
    @Test func adapterBytesPerKey() {
        // CHIE = 08/00, CH0J·CH0I = 01/00.
        let chie = SMCKeySelection.adapterKey(isAvailable: avail(["CHIE"]))
        #expect(chie?.disableBytes == [0x08]); #expect(chie?.enableBytes == [0x00])
        let ch0j = SMCKeySelection.adapterKey(isAvailable: avail(["CH0J"]))
        #expect(ch0j?.disableBytes == [0x01]); #expect(ch0j?.enableBytes == [0x00])
        let ch0i = SMCKeySelection.adapterKey(isAvailable: avail(["CH0I"]))
        #expect(ch0i?.disableBytes == [0x01]); #expect(ch0i?.enableBytes == [0x00])
    }

    // (c) ACLC LED는 어댑터 키 선택과 독립(분리).
    @Test func ledSelectedIndependentlyOfAdapter() {
        #expect(SMCKeySelection.dischargeLEDKey(isAvailable: avail(["ACLC"]))?.code == "ACLC")
        #expect(SMCKeySelection.dischargeLEDKey(isAvailable: avail([])) == nil)
        // 어댑터만 있고 LED 없음 → 어댑터는 선택, LED는 nil(상호 무영향).
        #expect(SMCKeySelection.adapterKey(isAvailable: avail(["CHIE"]))?.key.code == "CHIE")
        #expect(SMCKeySelection.dischargeLEDKey(isAvailable: avail(["CHIE"])) == nil)
        // LED만 있고 어댑터 없음 → 강제 방전 비활성이지만 LED 키는 존재.
        #expect(SMCKeySelection.adapterKey(isAvailable: avail(["ACLC"])) == nil)
        #expect(SMCKeySelection.dischargeLEDKey(isAvailable: avail(["ACLC"]))?.code == "ACLC")
    }

    @Test func chargeInhibitValueBytes() {
        // battery 정합 확인: CHTE 4B 01000000(중단)/00000000(허용).
        #expect(SMCKeys.chargeInhibitBytes == [0x01, 0x00, 0x00, 0x00])
        #expect(SMCKeys.chargeAllowBytes == [0x00, 0x00, 0x00, 0x00])
    }
}

@Suite struct SMCFloatTests {
    @Test func decodeFLTLittleEndian() {
        // 5.0f = 0x40A00000, little-endian bytes: 00 00 A0 40
        let v = SMCFloat.decodeFLT([0x00, 0x00, 0xA0, 0x40])
        #expect(v != nil)
        #expect(abs((v ?? 0) - 5.0) < 1e-6)
    }

    @Test func decodeFLTNegative() {
        // -12.5f = 0xC1480000, LE: 00 00 48 C1
        let v = SMCFloat.decodeFLT([0x00, 0x00, 0x48, 0xC1])
        #expect(abs((v ?? 0) + 12.5) < 1e-6)
    }

    @Test func decodeSP78() {
        // 1.5 in sp78 = 0x0180 → bytes 01 80
        let v = SMCFloat.decodeSP78([0x01, 0x80])
        #expect(abs((v ?? 0) - 1.5) < 1e-6)
    }

    @Test func wrongLengthReturnsNil() {
        #expect(SMCFloat.decodeFLT([0x00, 0x01]) == nil)
    }
}
