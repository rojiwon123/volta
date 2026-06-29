//
//  ControlCapabilityTests.swift
//  VoltaCoreTests
//
//  능력(capability)별 게이팅 + 효과검증 stale 판정 폐기(세대/적용상태)의 순수 로직 테스트.
//

import Testing
@testable import VoltaCore

@Suite struct ControlCapabilityTests {

    // MARK: 의도 ↔ 능력, 기능 ↔ 능력 매핑

    @Test func intentMapsToCapability() {
        #expect(ControlCapability(intent: .chargeInhibited) == .chargeInhibit)
        #expect(ControlCapability(intent: .adapterDisabled) == .adapterDisable)
    }

    @Test func featureCapabilityMapping() {
        // 충전 억제 패밀리.
        #expect(ControlFeature.chargeLimit.requiredCapability == .chargeInhibit)
        #expect(ControlFeature.heatProtection.requiredCapability == .chargeInhibit)
        #expect(ControlFeature.sleepChargeStop.requiredCapability == .chargeInhibit)
        #expect(ControlFeature.sleepInhibit.requiredCapability == .chargeInhibit)
        #expect(ControlFeature.tripPrep.requiredCapability == .chargeInhibit)
        // 어댑터 차단 패밀리.
        #expect(ControlFeature.forceDischarge.requiredCapability == .adapterDisable)
    }

    // MARK: 능력별 게이팅 — 한 능력 실패가 그 능력 기능만 가린다(수정 1 핵심)

    @Test func adapterIneffectiveHidesOnlyForceDischarge() {
        // 어댑터 차단만 미작동 → 강제 방전만 숨김, 충전 제한/과열/수면은 유지.
        let caps = ControlCapabilityState().setting(.adapterDisable, .ineffective(reason: "미반영"))
        func avail(_ f: ControlFeature) -> Bool {
            ControlAvailability.isFeatureAvailable(f, deviceWritable: true, helperReachable: true, capabilities: caps)
        }
        #expect(avail(.forceDischarge) == false)   // 가려짐
        #expect(avail(.chargeLimit) == true)       // 유지
        #expect(avail(.heatProtection) == true)
        #expect(avail(.sleepChargeStop) == true)
        #expect(avail(.tripPrep) == true)
        // 능력 중 하나(충전 억제)는 살아 있으므로 컨트롤 영역은 보인다.
        #expect(ControlAvailability.anyCapabilityAvailable(deviceWritable: true, helperReachable: true, capabilities: caps) == true)
    }

    @Test func chargeInhibitIneffectiveHidesItsFamilyButKeepsForceDischarge() {
        let caps = ControlCapabilityState().setting(.chargeInhibit, .ineffective(reason: "미반영"))
        func avail(_ f: ControlFeature) -> Bool {
            ControlAvailability.isFeatureAvailable(f, deviceWritable: true, helperReachable: true, capabilities: caps)
        }
        #expect(avail(.chargeLimit) == false)
        #expect(avail(.heatProtection) == false)
        #expect(avail(.sleepChargeStop) == false)
        #expect(avail(.tripPrep) == false)
        #expect(avail(.forceDischarge) == true)    // 어댑터 차단은 살아 있음 → 강제 방전 유지
        #expect(ControlAvailability.anyCapabilityAvailable(deviceWritable: true, helperReachable: true, capabilities: caps) == true)
    }

    @Test func bothIneffectiveHidesEverything() {
        let caps = ControlCapabilityState()
            .setting(.chargeInhibit, .ineffective(reason: "x"))
            .setting(.adapterDisable, .ineffective(reason: "y"))
        #expect(ControlAvailability.anyCapabilityAvailable(deviceWritable: true, helperReachable: true, capabilities: caps) == false)
    }

    @Test func deviceOrHelperGateOverridesEverything() {
        let caps = ControlCapabilityState()   // 전부 untested(낙관)
        // 기기 미지원 → 무엇도 사용 불가.
        #expect(ControlAvailability.isFeatureAvailable(.chargeLimit, deviceWritable: false, helperReachable: true, capabilities: caps) == false)
        // 헬퍼 미연결 → 무엇도 사용 불가.
        #expect(ControlAvailability.isFeatureAvailable(.chargeLimit, deviceWritable: true, helperReachable: false, capabilities: caps) == false)
        // 둘 다 충족 + untested → 사용 가능(낙관적).
        #expect(ControlAvailability.isFeatureAvailable(.chargeLimit, deviceWritable: true, helperReachable: true, capabilities: caps) == true)
    }

    // MARK: 헬퍼 미연결 시 능력별 비활성 자동 해제

    @Test func ineffectiveClearedWhenHelperUnreachable() {
        let caps = ControlCapabilityState().setting(.adapterDisable, .ineffective(reason: "x"))
        // 헬퍼 미연결 → ineffective 해제(untested). 헬퍼 연결 → 유지.
        #expect(caps.clearedIfWriteUnavailable(helperReachable: false).effectiveness(.adapterDisable) == .untested)
        #expect(caps.clearedIfWriteUnavailable(helperReachable: true).isIneffective(.adapterDisable) == true)
    }

    // MARK: 효과 → 능력 상태 반영

    @Test func applyingEffectUpdatesCapability() {
        let base = ControlCapabilityState()
        #expect(base.applyingControlEffect(.observed, capability: .chargeInhibit, reason: "").effectiveness(.chargeInhibit) == .effective)
        #expect(base.applyingControlEffect(.notObserved, capability: .chargeInhibit, reason: "r").isIneffective(.chargeInhibit) == true)
        #expect(base.applyingControlEffect(.inconclusive, capability: .chargeInhibit, reason: "").effectiveness(.chargeInhibit) == .untested)
    }

    @Test func promotedToVerifiedOnlyFromMappedUnverified() {
        #expect(DeviceSupportResult.supported(.mappedUnverified).promotedToVerified() == .supported(.verifiedOnHardware))
        #expect(DeviceSupportResult.supported(.verifiedOnHardware).promotedToVerified() == .supported(.verifiedOnHardware))
        #expect(DeviceSupportResult.unsupported(reason: "x").promotedToVerified() == .unsupported(reason: "x"))
    }
}

@Suite struct VerificationGatingTests {
    // 효과검증 stale 판정 폐기(수정 2): 예약 세대/적용상태가 유지될 때만 판정.

    // (a) 적용 후 intent 유지(세대 동일 + 여전히 적용 중) → 판정 진행 → notObserved면 강등.
    @Test func judgesWhenIntentHeld() {
        #expect(VerificationGating.shouldJudge(scheduledGeneration: 3, currentGeneration: 3, intentStillApplied: true) == true)
        // 판정 진행 + 미관찰 → 능력 ineffective.
        let caps = ControlCapabilityState().applyingControlEffect(.notObserved, capability: .adapterDisable, reason: "미반영")
        #expect(caps.isIneffective(.adapterDisable) == true)
    }

    // (b) 검증 완료 전 intent 해제(취소) → 적용 상태 아님 → 폐기(강등 안 함).
    @Test func discardsWhenIntentReleased() {
        #expect(VerificationGating.shouldJudge(scheduledGeneration: 3, currentGeneration: 3, intentStillApplied: false) == false)
    }

    // (b)/(c) 검증 중 제어가 바뀜(세대 불일치, 빠른 토글 포함) → 폐기.
    @Test func discardsWhenGenerationChanged() {
        // 강제 방전 적용(gen=5) → 취소(어댑터 재연결, gen=6) → 판정 시점 gen=6 ≠ 5 → 폐기.
        #expect(VerificationGating.shouldJudge(scheduledGeneration: 5, currentGeneration: 6, intentStillApplied: false) == false)
        // 빠른 토글로 off→on 두 번(gen 두 칸 점프) → 여전히 적용 중이어도 세대 불일치 → 폐기(stale 판정 없음).
        #expect(VerificationGating.shouldJudge(scheduledGeneration: 5, currentGeneration: 7, intentStillApplied: true) == false)
    }
}
