//
//  SMARTBattery.swift
//  VoltaCore
//
//  AppleSmartBattery IORegistry 읽기(기능 4). 비특권으로 접근 가능.
//   - RawCurrentCapacity / DesignCapacity → 하드웨어 실제 비율
//   - Temperature(0.01K 또는 0.1℃ 보고; 검증 필요), CycleCount, IsCharging, ExternalConnected
//
//  ⚠️ 실기 빌드 검증 필요. 프로퍼티 키 이름/단위는 모델별로 다를 수 있다.
//

#if canImport(IOKit)
import Foundation
import IOKit

public struct SMARTBatterySnapshot: Sendable {
    public var rawCurrentCapacity: Int?
    public var designCapacity: Int?
    /// 현재 완충 시 최대 용량(mAh). AppleSmartBattery["AppleRawMaxCapacity"]. 설계 용량 대비 배터리 수명 산출용.
    public var rawMaxCapacity: Int?
    public var temperatureCelsius: Double?
    public var cycleCount: Int?
    public var isCharging: Bool?
    public var externalConnected: Bool?
    /// 연결된 전원장치(어댑터)의 정격 와트(W). AdapterDetails["Watts"]. 미연결이면 nil.
    public var adapterRatedWatts: Double?

    // IOKit 전류·전압(SMC 전력키가 nil일 때 전력 W 폴백 산출용).
    /// 배터리 전류(mA, 부호: +충전 / −방전 = IOKit 규약). AppleSmartBattery["Amperage"].
    public var batteryAmperageMA: Int?
    /// 배터리 전압(mV). AppleSmartBattery["Voltage"].
    public var batteryVoltageMV: Int?
    /// 어댑터 전달 전류(mA). AdapterDetails["Current"].
    public var adapterCurrentMA: Int?
    /// 어댑터 전달 전압(mV). AdapterDetails["AdapterVoltage"].
    public var adapterVoltageMV: Int?

    /// 노트북 덮개 닫힘(클램셸) 여부. IOPMrootDomain["AppleClamshellState"]. 읽기 실패 시 nil.
    public var clamshellClosed: Bool?

    /// 하드웨어 실제 비율(%).
    public var hardwarePercent: Double? {
        guard let raw = rawCurrentCapacity, let design = designCapacity, design > 0 else { return nil }
        return Double(raw) / Double(design) * 100.0
    }

    /// 배터리 수명(%) = 현재 최대 용량 / 설계 용량 × 100. 둘 다 mAh 가정(모델별 차이 가능 — 검증 필요).
    public var healthPercent: Double? {
        guard let maxc = rawMaxCapacity, let design = designCapacity, design > 0 else { return nil }
        return Double(maxc) / Double(design) * 100.0
    }

    /// IOKit 전류×전압으로 산출한 배터리 전력(W). +충전 / −방전(PowerFlow.batteryPositiveMeansCharging=true와 동일 규약).
    public var batteryWattsIOKit: Double? {
        guard let a = batteryAmperageMA, let v = batteryVoltageMV, v > 0 else { return nil }
        return Double(a) * Double(v) / 1_000_000.0
    }
    /// AdapterDetails 전류×전압으로 산출한 어댑터 delivered 전력(W). 미연결/데이터 없음이면 nil.
    public var adapterWattsIOKit: Double? {
        guard let a = adapterCurrentMA, let v = adapterVoltageMV, a > 0, v > 0 else { return nil }
        return Double(a) * Double(v) / 1_000_000.0
    }
}

public enum SMARTBattery {

    /// IORegistry CFNumber → Int(부호 보존). `as? Int`는 64비트 음수(방전 Amperage가
    /// UInt64로 감싸진 경우 등)에서 nil로 떨어질 수 있어, NSNumber.int64Value로 재해석한다.
    private static func intValue(_ any: Any?) -> Int? {
        guard let n = any as? NSNumber else { return nil }
        return Int(n.int64Value)
    }

    /// AppleSmartBattery "Temperature"(1/100 ℃, centi-Celsius) → ℃.
    /// 단위 오해(K/deci 등) 재발에 대비해 **현실 범위(-20…120℃) 밖이면 nil**로 가드한다.
    /// (273.15를 빼던 과거 버그처럼 비상식적 값이 그대로 표시되지 않게.)
    static func celsiusFromCentiCelsius(_ raw: Int) -> Double? {
        let c = Double(raw) / 100.0
        return (-20.0...120.0).contains(c) ? c : nil
    }

    /// IOPMrootDomain에서 덮개 닫힘(클램셸) 상태를 읽는다. 키가 없거나 데스크탑이면 nil.
    /// ⚠️ 일부 모델/상황에서 키 부재 가능 → nil은 "알 수 없음"으로 다룬다(경고 미표시).
    private static func readClamshellClosed() -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let prop = IORegistryEntryCreateCFProperty(
            service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? Bool else { return nil }
        return prop
    }

    /// AppleSmartBattery 서비스에서 주요 프로퍼티를 읽는다.
    public static func read() -> SMARTBatterySnapshot {
        var snap = SMARTBatterySnapshot()
        snap.clamshellClosed = readClamshellClosed()

        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSmartBattery")
        )
        guard service != 0 else { return snap }
        defer { IOObjectRelease(service) }

        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == kIOReturnSuccess,
              let dict = props?.takeRetainedValue() as? [String: Any] else {
            return snap
        }

        snap.rawCurrentCapacity = intValue(dict["RawCurrentCapacity"])
        snap.designCapacity = intValue(dict["DesignCapacity"])
        snap.rawMaxCapacity = intValue(dict["AppleRawMaxCapacity"])
        snap.cycleCount = intValue(dict["CycleCount"])
        snap.isCharging = dict["IsCharging"] as? Bool
        snap.externalConnected = dict["ExternalConnected"] as? Bool

        // 배터리 전류/전압(전력 W 폴백용). Amperage는 부호 있는 값(+충전/−방전); 비현실값(±50A 초과)은 버림.
        // ⚠️ 방전 시 음수 Amperage가 핵심 — intValue로 부호 보존해 읽어야 battery→laptop 흐름이 생긴다.
        snap.batteryAmperageMA = intValue(dict["Amperage"]).flatMap { abs($0) <= 50_000 ? $0 : nil }
        snap.batteryVoltageMV = intValue(dict["Voltage"])

        // 어댑터: 정격(Watts) + delivered 산출용 전류/전압(Current, AdapterVoltage). 미연결 시 AdapterDetails 부재.
        // ⚠️ 키/단위 모델별 차이 가능(검증 필요). 실측(40W)에서 Watts=40, Current=2660mA, AdapterVoltage=15000mV → 39.9W 확인.
        if let ad = dict["AdapterDetails"] as? [String: Any] {
            if let watts = intValue(ad["Watts"]) { snap.adapterRatedWatts = Double(watts) }
            snap.adapterCurrentMA = intValue(ad["Current"])
            snap.adapterVoltageMV = intValue(ad["AdapterVoltage"])
        }

        // Temperature: AppleSmartBattery "Temperature"는 **1/100 ℃(centi-Celsius)** — ℃ = t/100.
        //  ⚠️ 과거엔 1/100 K로 오해해 273.15를 빼서 -242.9℃ 버그가 났다.
        //     실측 raw(Mac17,5) 3020 → 30.20℃, VirtualTemperature 2879 → 28.79℃로 확인.
        if let t = intValue(dict["Temperature"]) {
            snap.temperatureCelsius = celsiusFromCentiCelsius(t)
        }

        return snap
    }
}
#endif
