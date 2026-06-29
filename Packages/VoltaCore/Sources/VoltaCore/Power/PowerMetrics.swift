//
//  PowerMetrics.swift
//  VoltaCore
//
//  기능 6: 전력 흐름 메트릭. SMC의 PDTR/PPBR/PSTR 키를 flt(IEEE754 LE float)로 읽어
//  와트 단위로 노출한다.
//
//  ⚠️ 부호 규약(검증 필요):
//   - 아래 부호 해석은 일반적 관찰에 기반한 "가정"이며 실기에서 반드시 확인해야 한다.
//   - 예: 배터리 전력이 충전 시 +, 방전 시 -인지(혹은 반대인지)는 모델/펌웨어별로 다를 수 있다.
//

import Foundation

public struct PowerMetrics: Sendable, Equatable {
    /// 어댑터(델리버리) 입력 전력(W). SMC 키 PDTR 가정.
    public var adapterWatts: Double?

    /// 배터리 전력(W). SMC 키 PPBR 가정. 부호 규약은 검증 필요.
    public var batteryWatts: Double?

    /// 시스템 총 소비 전력(W). SMC 키 PSTR 가정.
    public var systemWatts: Double?

    /// 연결된 어댑터의 "정격" 와트(W) — 충전기 스펙. AdapterDetails["Watts"]. (delivered=adapterWatts와 구분)
    public var adapterRatedWatts: Double?

    public init(
        adapterWatts: Double? = nil,
        batteryWatts: Double? = nil,
        systemWatts: Double? = nil,
        adapterRatedWatts: Double? = nil
    ) {
        self.adapterWatts = adapterWatts
        self.batteryWatts = batteryWatts
        self.systemWatts = systemWatts
        self.adapterRatedWatts = adapterRatedWatts
    }

    /// 배터리가 충전 중인지 추정(부호 규약 검증 전이므로 보조 지표로만 사용).
    public var isBatteryChargingByPowerSign: Bool? {
        guard let w = batteryWatts else { return nil }
        // 가정: 양수 = 배터리로 유입(충전). 실기 검증 필요.
        return w > 0.05
    }

    /// 시스템(노트북) 소비 전력 유도: laptop = adapter(delivered) − battery(부호: +충전).
    ///  - 방전(어댑터 nil/0, battery −): laptop = −battery = |battery|.
    ///  - 충전(adapter +, battery +): laptop = adapter − 충전분.
    /// PSTR(시스템 SMC 키)이 없을 때의 폴백. 어댑터·배터리 둘 다 없으면 nil.
    public static func deriveSystemWatts(adapter: Double?, battery: Double?) -> Double? {
        guard adapter != nil || battery != nil else { return nil }
        return (adapter ?? 0) - (battery ?? 0)
    }
}
