//
//  SMCKey.swift
//  VoltaCore
//
//  SMC 키 정의. 4글자 FourCharCode.
//
//  ⚠️ 매직값/키 가용성 = 실기 검증 항목(docs/user-test-checklist.md 참조).
//  값 규약은 오픈소스 batt(charlie0129/batt)의 Tahoe 경로를 근거로 했으나,
//  모델/펌웨어에 따라 다를 수 있어 "검증 필요"로 둔다. 임의로 단정하지 않는다.
//

import Foundation

/// 4글자 SMC 키.
public struct SMCKey: Sendable, Hashable, CustomStringConvertible {
    public let code: String   // 예: "CHTE"
    public init(_ code: String) {
        precondition(code.utf8.count == 4, "SMC key must be 4 ASCII chars")
        self.code = code
    }
    public var description: String { code }

    /// FourCharCode(UInt32, big-endian ASCII)로 변환.
    public var fourCharCode: UInt32 {
        var result: UInt32 = 0
        for b in code.utf8 { result = (result << 8) | UInt32(b) }
        return result
    }
}

public enum SMCKeys {

    // MARK: 읽기 — 상태

    /// 충전 비율(%) 1바이트. (batt: BatteryChargeKey)
    public static let batteryCharge = SMCKey("BUIC")   // ⚠️ 검증 필요(모델별 상이: BBIF/BRSC 등 후보)

    /// 배터리 온도(℃, sp78/ioft). ⚠️ 키/타입 검증 필요.
    public static let batteryTemperature = SMCKey("TB0T")

    // MARK: 읽기 — 전력 메트릭 (기능 6, flt, 단위 W)

    /// 어댑터 전달 전력. ⚠️ 검증 필요.
    public static let powerAdapterDelivered = SMCKey("PDTR")
    /// 배터리 전력(부호 규약 검증 필요).
    public static let powerBattery = SMCKey("PPBR")
    /// 시스템 총 소비 전력.
    public static let powerSystemTotal = SMCKey("PSTR")

    // MARK: 쓰기 — 충전 억제 (기능 1)

    /// 충전 억제 키(Apple Silicon = CHTE 단일). 4바이트.
    ///  - 충전 허용:   00 00 00 00
    ///  - 충전 중단:   01 00 00 00
    /// battery 정합: Tahoe는 CHTE 단일. **구형 CH0B/CH0C(Intel 듀얼)는 의도적으로 미사용**(AS 전용).
    /// ⚠️ 실제 FourCC/효과는 미검증(유료 팀/실기 전).
    public static let chargeInhibit = SMCKey("CHTE")
    public static let chargeAllowBytes: [UInt8]  = [0x00, 0x00, 0x00, 0x00]
    public static let chargeInhibitBytes: [UInt8] = [0x01, 0x00, 0x00, 0x00]

    // MARK: 쓰기 — 어댑터 차단 / 강제 방전 (기능 3) — probe 폴백 체인

    /// 어댑터 제어 키 1개와 그 차단/해제 바이트값.
    public struct AdapterKey: Sendable, Equatable {
        public let key: SMCKey
        /// 어댑터 끊음(= 강제 방전).
        public let disableBytes: [UInt8]
        /// 어댑터 정상(= 해제).
        public let enableBytes: [UInt8]
        public init(_ key: SMCKey, disable: [UInt8], enable: [UInt8]) {
            self.key = key; self.disableBytes = disable; self.enableBytes = enable
        }
    }

    /// 어댑터 차단(강제 방전) **폴백 체인** — 우선순위 순. battery 정합:
    /// CHIE(0x08 방전 / 0x00 해제) → CH0J(0x01 / 0x00) → CH0I(0x01 / 0x00).
    /// **존재하는 첫 키만** 사용하고(probe), 셋 다 없으면 강제 방전 비활성(fail-safe, write 안 함).
    /// ⚠️ 실제 FourCC/값/효과는 미검증(유료 팀/실기 전).
    public static let adapterFallbackChain: [AdapterKey] = [
        AdapterKey(SMCKey("CHIE"), disable: [0x08], enable: [0x00]),
        AdapterKey(SMCKey("CH0J"), disable: [0x01], enable: [0x00]),
        AdapterKey(SMCKey("CH0I"), disable: [0x01], enable: [0x00]),
    ]

    // MARK: 쓰기 — 방전 중 MagSafe LED (외관, 기능 무관)

    /// 방전 중 MagSafe LED 색. 시작 0x01 / 해제 0x00. **존재할 때만** write하며 실패해도 무시
    /// (강제 방전 기능과 완전 분리). battery: ACLC.
    public static let dischargeLED = SMCKey("ACLC")
    public static let dischargeLEDOnBytes: [UInt8]  = [0x01]
    public static let dischargeLEDOffBytes: [UInt8] = [0x00]

    /// 가용성(존재)을 확인할 모든 키 — write 경로의 probe 기반 키 선택에 사용.
    public static let allProbed: [SMCKey] = [
        batteryCharge, batteryTemperature,
        powerAdapterDelivered, powerBattery, powerSystemTotal,
        chargeInhibit, dischargeLED,
    ] + adapterFallbackChain.map(\.key)
}

/// SMC 키 선택(probe 기반, **순수 함수** — 단위 테스트 대상). 가용성 술어를 받아 존재하는 키를 고른다.
/// 실제 키 존재 판별은 `SMCKit.keyExists`(메타 조회)로, 효과는 서명된 root 헬퍼 실기에서만 확정.
public enum SMCKeySelection {
    /// 충전 억제 키(CHTE). 없으면 nil → 충전 제어 no-op(fail-safe).
    public static func chargeInhibitKey(isAvailable: (SMCKey) -> Bool) -> SMCKey? {
        isAvailable(SMCKeys.chargeInhibit) ? SMCKeys.chargeInhibit : nil
    }
    /// 어댑터 차단 키(폴백 우선순위 첫 가용 키). 셋 다 없으면 nil → 강제 방전 비활성(fail-safe).
    public static func adapterKey(isAvailable: (SMCKey) -> Bool) -> SMCKeys.AdapterKey? {
        SMCKeys.adapterFallbackChain.first { isAvailable($0.key) }
    }
    /// 방전 LED 키(ACLC). 없으면 nil → LED 미설정(외관, 기능 무관 — 어댑터 키 선택과 독립).
    public static func dischargeLEDKey(isAvailable: (SMCKey) -> Bool) -> SMCKey? {
        isAvailable(SMCKeys.dischargeLED) ? SMCKeys.dischargeLED : nil
    }
}
