//
//  DeviceSupport.swift
//  VoltaCore
//
//  기기 지원 판별(capability gating). 아키텍처 + 모델 식별자로 "이 기기에서 SMC 제어를
//  활성화할지"를 결정한다. **Apple Silicon 전용** — Intel/미등록 모델은 미지원(fail-safe).
//
//  미지원 판정 시 호출측(SMCService 쓰기, UI)은 SMC 쓰기를 no-op 처리하고 제어 기능을 비활성화한다.
//

import Foundation

/// allowlist 항목의 검증 상태.
/// - verifiedOnHardware: 실기에서 SMC 키/매직값/효과까지 검증됨.
/// - mappedUnverified: 키 세트는 매핑됐으나 효과는 미검증(예: 유료 팀 계정 전이라 헬퍼 설치·실기 검증 불가).
public enum VerificationStatus: String, Sendable, Equatable {
    case verifiedOnHardware
    case mappedUnverified
}

/// 지원 판별 결과.
public enum DeviceSupportResult: Sendable, Equatable {
    /// 지원(검증 상태 동반).
    case supported(VerificationStatus)
    /// 미지원(아키텍처/모델 — 정적 판정).
    case unsupported(reason: String)
    /// **런타임 강등**: 정적으론 지원이나, write 후 기대 거동이 관찰되지 않아 "제어가 이 기기에서
    /// 안 먹는 것"으로 판단된 상태(효과 검증 실패). 이후 제어를 비활성하고 안전 상태로 수렴한다.
    case ineffective(reason: String)

    /// SMC 쓰기를 시도해도 되는지. 미지원·런타임 강등이면 false(no-op).
    public var allowsSMCWrites: Bool {
        if case .supported = self { return true }
        return false
    }

    /// 사람이 읽을 한국어 요약(UI 안내용).
    public var summary: String {
        switch self {
        case .supported(.verifiedOnHardware): return "지원 기기(실기 검증됨)"
        case .supported(.mappedUnverified):   return "지원 기기(키 매핑됨·효과 미검증)"
        case .unsupported(let reason):        return "미지원: \(reason)"
        case .ineffective(let reason):        return "제어 미작동(효과 미관찰): \(reason)"
        }
    }

    /// 효과 검증 결과로 **런타임 강등**한 새 상태를 반환한다(순수).
    /// - notObserved(write됐는데 거동 안 바뀜) → `.ineffective`로 강등.
    /// - observed/inconclusive → 그대로 유지(불확실하면 강등하지 않음 — false-downgrade 방지).
    /// - 이미 supported가 아니면(이미 미지원/강등) 그대로.
    public func applyingControlEffect(_ effect: ControlEffect, reason: String) -> DeviceSupportResult {
        guard case .supported = self else { return self }
        return effect == .notObserved ? .ineffective(reason: reason) : self
    }

    /// 헬퍼가 enabled가 아니면(미설치/미연결) 런타임 강등(`.ineffective`)을 **표시/유지하지 않고** base로 되돌린다.
    /// 헬퍼가 없으면 SMC write 자체가 안 일어나 "효과 미관찰"을 단정할 수 없으므로, 헬퍼 부재는
    /// `.ineffective`가 아니라 기존 헬퍼 상태 안내(HelperStatusView) 경로로만 표시되게 한다.
    public func clearedIfControlWriteUnavailable(helperEnabled: Bool, base: DeviceSupportResult) -> DeviceSupportResult {
        if case .ineffective = self, !helperEnabled { return base }
        return self
    }
}

public enum DeviceSupport {

    /// allowlist 항목: (등록 모델들) → 사용할 SMC 키 세트 + 검증 상태.
    public struct Entry: Sendable, Equatable {
        /// 등록된 모델 식별자(정확 일치). 예: ["Mac17,5"].
        public let models: Set<String>
        /// 사용할 SMC 키 세트 이름. 현재는 Tahoe(26) 기본 1종.
        public let keyProfile: String
        public let verification: VerificationStatus
        public init(models: Set<String>, keyProfile: String, verification: VerificationStatus) {
            self.models = models
            self.keyProfile = keyProfile
            self.verification = verification
        }
    }

    /// 사용할 SMC 키 세트 이름(현재 Tahoe 26 경로 1종 — SMCKeys).
    public static let tahoeDefaultProfile = "tahoe-default"

    /// 지원 모델 allowlist. **arm64 머신에서만 유효**(아래 evaluate가 isAppleSilicon을 먼저 검사).
    /// ⚠️ 검증 상태는 솔직히 표기: 유료 팀 계정 전이라 실기 효과 미검증 → mappedUnverified.
    public static let allowlist: [Entry] = [
        Entry(models: ["Mac17,5"], keyProfile: tahoeDefaultProfile, verification: .mappedUnverified),
    ]

    /// 주어진 기기 정보로 지원 여부를 판정한다.
    public static func evaluate(_ info: DeviceInfo) -> DeviceSupportResult {
        guard info.isAppleSilicon else {
            return .unsupported(reason: "Apple Silicon 전용 — Intel(\(info.architecture)) 미지원")
        }
        guard let entry = allowlist.first(where: { $0.models.contains(info.modelIdentifier) }) else {
            return .unsupported(reason: "미등록 모델(\(info.modelIdentifier)) — allowlist에 없음")
        }
        return .supported(entry.verification)
    }

    /// 현재 이 기기의 지원 판정(편의).
    public static var current: DeviceSupportResult { evaluate(.current) }
}
