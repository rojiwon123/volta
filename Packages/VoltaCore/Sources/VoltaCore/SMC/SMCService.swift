//
//  SMCService.swift
//  VoltaCore
//
//  SMC 접근을 직렬화하는 actor. 폴링 읽기와 (헬퍼 측) 쓰기를 한 곳에서 순서 보장.
//  - 앱: read*()만 사용(비특권).
//  - 헬퍼(root): write*() 사용.
//
//  플랫폼 가드: IOKit 없는 환경에서는 stub(빈 reading)로 대체해 컴파일 가능하게 유지.
//

import Foundation

public actor SMCService {

    public init() {}

#if canImport(IOKit)
    private let smc = SMCKit()
    private var isOpen = false
    /// 키 가용성 캐시(펌웨어/모델 분기용).
    private var capabilities: [String: Bool] = [:]

    /// 기기 지원 판정(capability gating). 미지원이면 SMC 쓰기는 no-op(fail-safe).
    /// 1회 평가 후 캐시 — 아키텍처/모델은 런타임 중 바뀌지 않는다.
    private lazy var support: DeviceSupportResult = DeviceSupport.current

    /// 현재 기기의 지원 판정(앱/헬퍼 진단용).
    public var deviceSupport: DeviceSupportResult { support }

    private func ensureOpen() throws {
        guard !isOpen else { return }
        try smc.open()
        isOpen = true
        // 키 존재는 메타정보(keyExists)로 확인 — write-only 제어 키(CHTE/CHIE 등)는 값 읽기로는
        // false-negative가 날 수 있어서다. (값 읽기는 readBattery가 키별로 별도 try?로 처리.)
        for key in SMCKeys.allProbed {
            capabilities[key.code] = smc.keyExists(key)
        }
    }

    public func shutdown() {
        smc.close()
        isOpen = false
    }

    /// 한 시점의 통합 reading(기능 4·5·6). AppleSmartBattery + SMC 전력값.
    public func readBattery() -> BatteryReading {
        try? ensureOpen()

        let sb = SMARTBattery.read()

        // 전력 W: SMC 전력키(PDTR/PPBR/PSTR) 우선, 이 맥에서 안 읽히면 IOKit(전류×전압)로 폴백.
        // → SMC 키가 없는 모델에서도 전력 흐름이 보이게(특히 배터리 방전 모드에서 battery→laptop).
        var power = PowerMetrics()
        let acOn = sb.externalConnected == true
        power.adapterWatts = readFLT(SMCKeys.powerAdapterDelivered) ?? (acOn ? sb.adapterWattsIOKit : nil)

        // 배터리 전력 W + 부호.
        // ⚠️ 이 맥의 PPBR(SMC)은 "크기만" 보고하고 부호가 없다(방전 중에도 양수). 그래서 PPBR을
        //    충전/방전 방향 판단에 쓰면 방전이 충전으로 오분류돼 전력 흐름이 사라진다.
        //    → 크기는 PPBR(있으면) 우선·없으면 IOKit, 방향(부호)은 IOKit isCharging / Amperage 부호로 결정.
        let batteryMagnitude = readFLT(SMCKeys.powerBattery).map(abs) ?? sb.batteryWattsIOKit.map(abs)
        let isChargingDir = sb.isCharging ?? ((sb.batteryAmperageMA ?? 0) > 0)
        power.batteryWatts = batteryMagnitude.map { isChargingDir ? $0 : -$0 }

        power.systemWatts  = readFLT(SMCKeys.powerSystemTotal)
            ?? PowerMetrics.deriveSystemWatts(adapter: power.adapterWatts, battery: power.batteryWatts)
        power.adapterRatedWatts = sb.adapterRatedWatts    // 충전기 정격(IORegistry AdapterDetails)

        // 온도: SMC sp78 우선, 없으면 AppleSmartBattery.
        let smcTemp = readSP78(SMCKeys.batteryTemperature)

        return BatteryReading(
            osChargePercent: batteryChargeUInt8(),
            hardwareChargePercent: sb.hardwarePercent,
            temperatureCelsius: smcTemp ?? sb.temperatureCelsius,
            isCharging: sb.isCharging ?? false,
            isACPresent: sb.externalConnected ?? false,
            isClamshellLikely: sb.clamshellClosed ?? false, // IOPMrootDomain.AppleClamshellState (덮개 닫힘)
            cycleCount: sb.cycleCount,
            batteryHealthPercent: sb.healthPercent,
            power: power
        )
    }

    private func batteryChargeUInt8() -> Int? {
        guard let bytes = try? smc.read(SMCKeys.batteryCharge) else { return nil }
        return SMCFloat.decodeUInt8(bytes)
    }

    private func readFLT(_ key: SMCKey) -> Double? {
        guard let bytes = try? smc.read(key) else { return nil }
        return SMCFloat.decodeFLT(bytes)
    }

    private func readSP78(_ key: SMCKey) -> Double? {
        guard let bytes = try? smc.read(key) else { return nil }
        return SMCFloat.decodeSP78(bytes)
    }

    // MARK: 쓰기 (root 헬퍼에서만 호출)

    public func setChargingAllowed(_ allowed: Bool) throws {
        guard support.allowsSMCWrites else { return }   // 미지원 기기: no-op(fail-safe).
        try ensureOpen()
        // probe로 충전 억제 키(CHTE) 존재 확인 후에만 write. 없으면 no-op(blind-write 금지).
        guard let key = SMCKeySelection.chargeInhibitKey(isAvailable: { isKeyAvailable($0) }) else { return }
        let bytes = allowed ? SMCKeys.chargeAllowBytes : SMCKeys.chargeInhibitBytes
        try smc.write(key, bytes: bytes)
    }

    public func setAdapterEnabled(_ enabled: Bool) throws {
        guard support.allowsSMCWrites else { return }   // 미지원 기기: no-op(fail-safe).
        try ensureOpen()
        // 폴백 체인(CHIE→CH0J→CH0I)에서 probe로 존재하는 첫 키만 사용. 셋 다 없으면 강제 방전 비활성(no-op).
        guard let adapter = SMCKeySelection.adapterKey(isAvailable: { isKeyAvailable($0) }) else { return }
        let bytes = enabled ? adapter.enableBytes : adapter.disableBytes
        try smc.write(adapter.key, bytes: bytes)
        // 방전 중 MagSafe LED(외관) — 강제 방전 기능과 완전 분리: 존재할 때만, 실패해도 무시.
        applyDischargeLED(active: !enabled)
    }

    /// 방전 LED(ACLC) 적용. probe로 존재할 때만 write하고 실패는 무시(기능 무관).
    private func applyDischargeLED(active: Bool) {
        guard let led = SMCKeySelection.dischargeLEDKey(isAvailable: { isKeyAvailable($0) }) else { return }
        let bytes = active ? SMCKeys.dischargeLEDOnBytes : SMCKeys.dischargeLEDOffBytes
        try? smc.write(led, bytes: bytes)
    }

    public func isKeyAvailable(_ key: SMCKey) -> Bool {
        capabilities[key.code] ?? false
    }

    /// **행동 기반 효과 검증** — 제어 키 write 후 정착시켜 샘플한 배터리 거동(before/after)으로
    /// 기대 효과가 실제로 나타났는지 판정한다. write-only 제어 키(CHTE/CHIE)는 값 read-back을 신뢰
    /// 못 하므로 거동 검증이 핵심. (값 read-back은 의미 있는 키에서만 보조 — 현재 미사용.)
    /// write는 호출측(setChargingAllowed/setAdapterEnabled)이 먼저 수행하고, before/after 샘플은
    /// `readBattery()`로 수집해 넘긴다.
    /// ⚠️ 판정은 "주어진 샘플상"일 뿐 — **실제 SMC 효과는 서명된 root 헬퍼·실기에서만 확정**된다(미검증).
    public nonisolated func verifyControlEffect(
        intent: ControlIntent,
        before: BatteryReading,
        after: [BatteryReading],
        policy: EffectSamplingPolicy = .default
    ) -> ControlEffect {
        ControlEffectVerifier.judge(intent: intent, before: before, after: after, policy: policy)
    }

#else
    // IOKit 미존재 환경(예: Linux CI): 컴파일만 통과시키는 stub.
    public var deviceSupport: DeviceSupportResult { DeviceSupport.current }
    public func shutdown() {}
    public func readBattery() -> BatteryReading { .unknown }
    public func setChargingAllowed(_ allowed: Bool) throws {}   // 미지원: no-op
    public func setAdapterEnabled(_ enabled: Bool) throws {}    // 미지원: no-op
    public func isKeyAvailable(_ key: SMCKey) -> Bool { false }
    public nonisolated func verifyControlEffect(
        intent: ControlIntent, before: BatteryReading, after: [BatteryReading],
        policy: EffectSamplingPolicy = .default
    ) -> ControlEffect {
        ControlEffectVerifier.judge(intent: intent, before: before, after: after, policy: policy)
    }
#endif
}
