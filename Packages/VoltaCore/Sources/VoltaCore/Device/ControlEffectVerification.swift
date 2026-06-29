//
//  ControlEffectVerification.swift
//  VoltaCore
//
//  행동(거동) 기반 효과 검증. 제어 키를 write한 뒤 **배터리/전력 거동이 실제로 바뀌었는지**를
//  before/after 샘플로 판정한다. CHTE/CHIE는 write-only라 "값 read-back"은 신뢰 못 하므로,
//  거동 검증이 핵심이다(값 read-back은 의미 있는 키에서만 보조 — 현재는 미사용).
//
//  ⚠️ 이 판정 로직은 순수 함수(단위 테스트 대상)다. **실제 SMC 효과는 서명된 root 헬퍼·실기에서만 확정**된다
//     — 여기서 .observed/.notObserved는 "주어진 샘플상" 판정일 뿐, 실기 효과를 검증한 것이 아니다.
//

import Foundation

/// 검증할 제어 의도.
public enum ControlIntent: Sendable, Equatable {
    /// 충전 억제(CHTE) 적용 — 적용 후 충전이 멈춰야 한다.
    case chargeInhibited
    /// 어댑터 차단/강제 방전(CHIE/CH0J/CH0I) 적용 — AC인데 배터리가 방전돼야 한다.
    case adapterDisabled
}

/// 거동 관찰 결과.
public enum ControlEffect: Sendable, Equatable {
    /// 기대 거동 관찰됨(제어가 먹은 것으로 보임).
    case observed
    /// write됐는데 기대 거동이 안 나타남(제어가 안 먹는 것으로 보임) → fail-safe·강등.
    case notObserved
    /// 판단 불가(검증 조건 불충족/데이터 부족/노이즈) → 강등하지 않음.
    case inconclusive
}

/// 정착 지연 + 샘플링 정책. (실시간 지연은 호출측이, 여기선 "버릴 초기 샘플 수 + 최소 결정 샘플 수"만.)
public struct EffectSamplingPolicy: Sendable, Equatable {
    /// 정착 위해 버리는 초기 after 샘플 수(SMC/OS 반영 시간차 흡수).
    public let settleSamples: Int
    /// 판정에 필요한 최소 결정 샘플 수(미만이면 inconclusive — 즉시 판정 금지).
    public let minDecisiveSamples: Int
    public init(settleSamples: Int = 1, minDecisiveSamples: Int = 2) {
        self.settleSamples = max(0, settleSamples)
        self.minDecisiveSamples = max(1, minDecisiveSamples)
    }
    public static let `default` = EffectSamplingPolicy()
}

/// 효과검증 **판정 게이팅**(순수). 검증을 예약한 시점과 판정 시점 사이에 그 제어가 바뀌면(세대 불일치)
/// 또는 더 이상 그 의도가 적용 중이 아니면(취소/해제) 판정을 **폐기**해야 한다. 그러지 않으면 "취소 후 상태"
/// (예: 강제 방전을 끈 직후의 어댑터 재연결 상태)를 보고 `.notObserved`로 오판해 잘못 강등한다.
public enum VerificationGating {
    /// true면 판정 진행, false면 폐기(강등/승격 금지 — inconclusive 취급).
    /// - scheduledGeneration: 검증 예약 시점의 능력별 세대(적용값 변화마다 증가).
    /// - currentGeneration: 판정 시점의 세대. 다르면 그새 제어가 바뀐 것 → 폐기.
    /// - intentStillApplied: 판정 시점에 그 의도가 여전히 적용 중인지(충전 억제=충전 불가, 어댑터 차단=어댑터 꺼짐).
    public static func shouldJudge(scheduledGeneration: Int, currentGeneration: Int, intentStillApplied: Bool) -> Bool {
        scheduledGeneration == currentGeneration && intentStillApplied
    }
}

public enum ControlEffectVerifier {

    /// 효과 검증을 **트리거해도 되는지**(순수). 헬퍼로 SMC write가 **실제 수행(성공)** 됐고 제어가 활성일
    /// 때만 true. write 미수행(헬퍼 미설치/미연결/연결 실패/거부)에는 false → 검증도 강등도 안 한다.
    /// (헬퍼가 없어 write 자체가 안 일어난 정상 상태를 "효과 미관찰"로 오판하지 않기 위함.)
    public static func shouldVerify(writePerformed: Bool, controlSupported: Bool) -> Bool {
        writePerformed && controlSupported
    }

    /// 전력 임계(W). 이 미만 절대값은 "흐름 없음(유지)"으로 본다.
    public static let wattsEpsilon = 0.5

    /// **실제 충전 중인지** — 배터리로 전류가 실제 유입(watts > +eps)될 때만 true.
    /// OS `isCharging` 플래그는 **상한 도달/유지(bypass) 상태에서도 true**로 뜰 수 있고(실전류는 ~0),
    /// 그걸 "충전 중"으로 보면 효과검증이 "멈출 충전이 없음"을 `notObserved`로 오판한다(충전 억제 미작동 오탐).
    /// 그래서 실측 전력을 우선하고, 전력 미측정 기기(batteryWatts=nil)에서만 OS 플래그로 폴백한다.
    public static func isChargingNow(_ r: BatteryReading) -> Bool {
        if let w = r.power.batteryWatts { return w > wattsEpsilon }
        return r.isCharging
    }
    /// 실제 방전 중인지 — 배터리에서 전류가 빠져나갈(watts < -eps) 때만 true.
    public static func isDischargingNow(_ r: BatteryReading) -> Bool {
        (r.power.batteryWatts ?? 0) < -wattsEpsilon
    }

    /// 효과검증 **전제조건** 미충족 사유(순수, 진단/로그용). nil이면 판정 가능(전제 충족).
    /// judge 내부 가드와 동일 기준 — "효과를 관찰할 상황이 아니면" 실패(notObserved)로 단정하지 않고 보류한다.
    public static func preconditionFailureReason(intent: ControlIntent, before: BatteryReading) -> String? {
        switch intent {
        case .chargeInhibited:
            return isChargingNow(before) ? nil : "직전 실제 충전 아님(상한 유지/만충 등 — 멈출 충전 없음)"
        case .adapterDisabled:
            if !before.isACPresent { return "AC 미연결" }
            if isDischargingNow(before) { return "직전 이미 방전(관찰 불가)" }
            return nil
        }
    }

    /// before(적용 직전) → after(정착 후 샘플들) 거동 변화를 판정한다(순수).
    public static func judge(
        intent: ControlIntent,
        before: BatteryReading,
        after: [BatteryReading],
        policy: EffectSamplingPolicy = .default
    ) -> ControlEffect {
        // 정착 샘플 버리고, 최소 결정 샘플 수 확보 못 하면 판단 보류(즉시 판정 금지).
        let decisive = Array(after.dropFirst(policy.settleSamples))
        guard decisive.count >= policy.minDecisiveSamples else { return .inconclusive }

        switch intent {
        case .chargeInhibited:
            // 검증 의미가 있으려면 적용 직전 "충전 중"이었어야 한다(아니면 멈춤이 억제 효과인지 알 수 없음).
            guard isChargingNow(before) else { return .inconclusive }
            let stillCharging = decisive.filter(isChargingNow).count
            if stillCharging == 0 { return .observed }            // 전부 멈춤 → 억제 먹음
            if stillCharging == decisive.count { return .notObserved }  // 전부 여전히 충전 → 억제 안 먹음
            return .inconclusive                                 // 혼재 → 보류(false-downgrade 방지)

        case .adapterDisabled:
            // 검증 의미가 있으려면 적용 직전 AC 연결 & 방전 아님(충전/유지)이었어야 한다.
            guard before.isACPresent, !isDischargingNow(before) else { return .inconclusive }
            let discharging = decisive.filter(isDischargingNow).count
            if discharging == decisive.count { return .observed }   // 전부 방전 → 어댑터 차단 먹음
            if discharging == 0 { return .notObserved }             // 전부 방전 아님 → 차단 안 먹음
            return .inconclusive
        }
    }
}
