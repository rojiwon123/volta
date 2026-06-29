//
//  BatteryReading.swift
//  VoltaCore
//
//  한 시점의 배터리/전력 상태 스냅샷. actor → UI/정책으로 안전히 넘기기 위해 Sendable.
//

import Foundation

public struct BatteryReading: Sendable, Equatable {
    /// OS가 보고하는 충전 비율(0~100). AppleSmartBattery의 CurrentCapacity 기반.
    public var osChargePercent: Int?

    /// 하드웨어 실제 비율(RawCurrentCapacity / DesignCapacity * 100).
    /// 기능 4: OS 표시값과 달리 보정 전 실제 용량 비율.
    public var hardwareChargePercent: Double?

    /// 배터리 온도(℃). 기능 5(Heat Protection) 판단용.
    public var temperatureCelsius: Double?

    /// 현재 충전 중인지(전류가 배터리로 유입).
    public var isCharging: Bool

    /// 외부 전원(어댑터) 연결 여부.
    public var isACPresent: Bool

    /// 뚜껑이 닫힌 클램셸 상태로 추정되는지(외부 디스플레이 사용 등).
    /// 기능 3: 클램셸에서는 방전 제어가 제한될 수 있음.
    public var isClamshellLikely: Bool

    /// 사이클 수(가능 시).
    public var cycleCount: Int?

    /// 배터리 수명(%) = 현재 최대 용량 / 설계 용량 × 100. 표시용(가능 시).
    public var batteryHealthPercent: Double?

    /// 전력 흐름 메트릭(기능 6).
    public var power: PowerMetrics

    public init(
        osChargePercent: Int? = nil,
        hardwareChargePercent: Double? = nil,
        temperatureCelsius: Double? = nil,
        isCharging: Bool = false,
        isACPresent: Bool = false,
        isClamshellLikely: Bool = false,
        cycleCount: Int? = nil,
        batteryHealthPercent: Double? = nil,
        power: PowerMetrics = .init()
    ) {
        self.osChargePercent = osChargePercent
        self.hardwareChargePercent = hardwareChargePercent
        self.temperatureCelsius = temperatureCelsius
        self.isCharging = isCharging
        self.isACPresent = isACPresent
        self.isClamshellLikely = isClamshellLikely
        self.cycleCount = cycleCount
        self.batteryHealthPercent = batteryHealthPercent
        self.power = power
    }

    /// 비어있는(데이터 없음) 스냅샷.
    public static let unknown = BatteryReading()
}
