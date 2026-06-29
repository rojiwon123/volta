//
//  PowerFlowTests.swift
//  VoltaCoreTests
//
//  raw 전력 메트릭 → 소스/sink 엣지 변환 로직 단위 테스트. (배터리 부호 가정 기준)
//

import Testing
@testable import VoltaCore

@Suite struct PowerFlowTests {

    private func has(_ f: PowerFlow, _ from: PowerFlow.Node, _ to: PowerFlow.Node, _ w: Double) -> Bool {
        f.edges.contains(.init(from: from, to: to, watts: w))
    }

    @Test func chargingSplitsAdapterToLaptopAndBattery() {
        // 충전: 어댑터 → 노트북(system) + 어댑터 → 배터리(charge). 배터리는 우측 sink.
        let p = PowerMetrics(adapterWatts: 36, batteryWatts: 15.5, systemWatts: 20.2)
        let f = PowerFlow.from(power: p, isACPresent: true)
        #expect(has(f, .adapter, .laptop, 20.2))
        #expect(has(f, .adapter, .battery, 15.5))
        #expect(!f.edges.contains { $0.from == .battery })   // 배터리는 소스(좌)가 아님
    }

    @Test func dischargeMixOnAC() {
        // 보조 방전: 어댑터 → 노트북 + 배터리 → 노트북.
        let p = PowerMetrics(adapterWatts: 28, batteryWatts: -33, systemWatts: 61)
        let f = PowerFlow.from(power: p, isACPresent: true)
        #expect(has(f, .adapter, .laptop, 28))
        #expect(has(f, .battery, .laptop, 33))
    }

    @Test func batteryOnlyWhenUnplugged() {
        let p = PowerMetrics(adapterWatts: nil, batteryWatts: -20, systemWatts: 20)
        let f = PowerFlow.from(power: p, isACPresent: false)
        #expect(f.edges == [.init(from: .battery, to: .laptop, watts: 20)])
    }

    @Test func adapterOnlyWhenBatteryIdle() {
        let p = PowerMetrics(adapterWatts: 30, batteryWatts: 0, systemWatts: 30)
        let f = PowerFlow.from(power: p, isACPresent: true)
        #expect(f.edges == [.init(from: .adapter, to: .laptop, watts: 30)])
    }

    @Test func adapterHiddenWhenNotACPresent() {
        let p = PowerMetrics(adapterWatts: 30, batteryWatts: -10, systemWatts: 10)
        let f = PowerFlow.from(power: p, isACPresent: false)
        #expect(!f.edges.contains { $0.from == .adapter || $0.to == .adapter })
        #expect(has(f, .battery, .laptop, 10))
    }

    @Test func adapterRatedPassThroughOnlyWhenAC() {
        let p = PowerMetrics(adapterWatts: 30, batteryWatts: 0, systemWatts: 30, adapterRatedWatts: 96)
        #expect(PowerFlow.from(power: p, isACPresent: true).adapterRatedWatts == 96)
        #expect(PowerFlow.from(power: p, isACPresent: false).adapterRatedWatts == nil)   // 미연결 시 숨김
    }

    @Test func nearZeroAllHidden() {
        let p = PowerMetrics(adapterWatts: 0.2, batteryWatts: 0.1, systemWatts: 3)
        let f = PowerFlow.from(power: p, isACPresent: true)
        #expect(f.edges.isEmpty)
        #expect(f.systemWatts == 3)
    }

    @Test func activityMatchesFlow() {
        // 메뉴바 아이콘이 쓰는 분류 = 흐름과 동일 기준.
        #expect(PowerFlow.from(power: .init(adapterWatts: 36, batteryWatts: 15.5, systemWatts: 20.2), isACPresent: true).activity == .charging)
        #expect(PowerFlow.from(power: .init(adapterWatts: nil, batteryWatts: -20, systemWatts: 20), isACPresent: false).activity == .discharging)
        #expect(PowerFlow.from(power: .init(adapterWatts: 30, batteryWatts: 0, systemWatts: 30), isACPresent: true).activity == .holding)
        #expect(PowerFlow.from(power: .init(adapterWatts: 0.2, batteryWatts: 0.1, systemWatts: 3), isACPresent: false).activity == .idle)
        // AlDente식 외부 방전: OS의 AC신호가 false라도 배터리 방전이면 discharging(원인 무관).
        #expect(PowerFlow.from(power: .init(adapterWatts: 0.1, batteryWatts: -7.3, systemWatts: 8), isACPresent: false).activity == .discharging)
    }

    @Test func nearZeroEmptyEvenWithAdapterRated() {
        // "거의 없음" 프리뷰: 모든 전력이 임계값 이하 → 활성 엣지 0(노드도 0). 단, 어댑터 정격은 전달될 수 있다.
        // 뷰(PowerFlowView.layout)가 이 빈 그래프를 크래시 없이 처리해야 한다(과거 빈 배열 인덱싱 크래시 회귀 방지).
        let p = PowerMetrics(adapterWatts: 0.2, batteryWatts: 0.1, systemWatts: 3, adapterRatedWatts: 96)
        let f = PowerFlow.from(power: p, isACPresent: true)
        #expect(f.edges.isEmpty)
        #expect(f.adapterRatedWatts == 96)
    }
}

/// SMC 전력키가 없는 맥에서 IOKit(전류×전압)로 전력 W를 산출하는 폴백 검증.
@Suite struct PowerFallbackTests {

    @Test func systemDerivationDischarge() {
        // 방전: 어댑터 없음, battery −16.5 → laptop = |battery| = 16.5.
        #expect(PowerMetrics.deriveSystemWatts(adapter: nil, battery: -16.5) == 16.5)
    }
    @Test func systemDerivationCharge() {
        // 충전: adapter 36, battery +15 → laptop = adapter − 충전분 = 21.
        #expect(PowerMetrics.deriveSystemWatts(adapter: 36, battery: 15) == 21)
    }
    @Test func systemDerivationNilWhenNoData() {
        #expect(PowerMetrics.deriveSystemWatts(adapter: nil, battery: nil) == nil)
    }
    @Test func dischargeFromBatteryWattsShowsFlow() {
        // 방전 폴백: battery −16.5W만 있어도(어댑터/시스템 nil) PowerFlow가 battery→laptop 활성 엣지 생성(빈 그래프 아님).
        let p = PowerMetrics(adapterWatts: nil, batteryWatts: -16.5, systemWatts: 16.5)
        let f = PowerFlow.from(power: p, isACPresent: false)
        #expect(f.edges.contains { $0.from == .battery && $0.to == .laptop && abs($0.watts - 16.5) < 0.01 })
    }

    #if canImport(IOKit)
    @Test func batteryWattsFromIOKitDischarge() {
        // −1500mA × 11000mV = −16.5W (방전, 부호 보존).
        let s = SMARTBatterySnapshot(batteryAmperageMA: -1500, batteryVoltageMV: 11000)
        #expect(abs((s.batteryWattsIOKit ?? 0) - (-16.5)) < 0.01)
    }
    @Test func batteryWattsFromIOKitCharge() {
        let s = SMARTBatterySnapshot(batteryAmperageMA: 1200, batteryVoltageMV: 12000)
        #expect(abs((s.batteryWattsIOKit ?? 0) - 14.4) < 0.01)
    }
    @Test func batteryWattsNilWhenMissing() {
        #expect(SMARTBatterySnapshot(batteryVoltageMV: 11000).batteryWattsIOKit == nil)
        #expect(SMARTBatterySnapshot(batteryAmperageMA: -1500).batteryWattsIOKit == nil)
    }
    @Test func adapterWattsFromIOKit() {
        // 실측값: 2660mA × 15000mV = 39.9W (≈정격 40W).
        let s = SMARTBatterySnapshot(adapterCurrentMA: 2660, adapterVoltageMV: 15000)
        #expect(abs((s.adapterWattsIOKit ?? 0) - 39.9) < 0.01)
    }
    @Test func healthPercentFromCapacities() {
        // 수명 = 최대 용량 / 설계 용량 × 100.
        var s = SMARTBatterySnapshot()
        s.rawMaxCapacity = 4200; s.designCapacity = 5000
        #expect(abs((s.healthPercent ?? 0) - 84.0) < 0.01)
    }
    @Test func healthPercentNilWhenMissing() {
        var s = SMARTBatterySnapshot()
        s.rawMaxCapacity = 4200   // 설계 용량 없음 → nil.
        #expect(s.healthPercent == nil)
    }

    // 온도: AppleSmartBattery "Temperature"는 1/100 ℃. raw/100 = ℃ (273.15 빼지 않는다).
    @Test func temperatureCentiCelsiusDecode() {
        // 실측 raw(Mac17,5): 3020 → 30.20℃, VirtualTemperature 2879 → 28.79℃, 힌트값 3025 → 30.25℃.
        #expect(abs((SMARTBattery.celsiusFromCentiCelsius(3020) ?? 0) - 30.20) < 0.001)
        #expect(abs((SMARTBattery.celsiusFromCentiCelsius(2879) ?? 0) - 28.79) < 0.001)
        #expect(abs((SMARTBattery.celsiusFromCentiCelsius(3025) ?? 0) - 30.25) < 0.001)
    }
    @Test func temperatureNotMisreadAsKelvin() {
        // 회귀: raw 3020이 -242℃ 같은 절대영도 근처 값으로 나오면 안 된다(273.15 빼기 버그).
        let c = SMARTBattery.celsiusFromCentiCelsius(3020) ?? 0
        #expect(c > 0); #expect(c < 60)
    }
    @Test func temperatureGuardsImplausibleValues() {
        // 단위 오해(예: K 스케일/deci) 재발 시 비상식적 값은 nil로 가드.
        #expect(SMARTBattery.celsiusFromCentiCelsius(30000) == nil)    // 300℃
        #expect(SMARTBattery.celsiusFromCentiCelsius(-30000) == nil)   // -300℃
        #expect(SMARTBattery.celsiusFromCentiCelsius(0) == 0.0)        // 0℃는 유효(현실 범위 내)
    }
    #endif
}
