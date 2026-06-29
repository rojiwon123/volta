//
//  HelperService.swift
//  voltaHelper
//
//  VoltaHelperProtocol 구현. SMC 특권 쓰기를 SMCService(actor)에 위임해 직렬화한다.
//  앱이 사전 푸시한 HelperPolicy를 보관해, sleep/wake 시 SleepWatcher가 참조한다.
//

import Foundation
import VoltaCore

final class HelperService: NSObject, VoltaHelperProtocol, @unchecked Sendable {

    static let shared = HelperService()

    private let smc = SMCService()
    private let lock = NSLock()
    private var _policy: HelperPolicy = .default
    private var _lastState: ChargeState = .suspended
    /// 마지막으로 어댑터를 끈 적이 있는지(복원 판단용).
    private var _adapterDisabled = false

    /// 현재 정책(스레드 안전 접근). set 시 항상 검증/클램프.
    var policy: HelperPolicy {
        get { lock.lock(); defer { lock.unlock() }; return _policy }
        set { lock.lock(); _policy = newValue.validated(); lock.unlock() }
    }

    private var lastState: ChargeState {
        get { lock.lock(); defer { lock.unlock() }; return _lastState }
        set { lock.lock(); _lastState = newValue; lock.unlock() }
    }

    // MARK: VoltaHelperProtocol

    func getVersion(reply: @escaping @Sendable (String) -> Void) {
        reply("voltaHelper 0.1.0")
    }

    func setChargingAllowed(_ allowed: Bool,
                            reply: @escaping @Sendable (Bool, String?) -> Void) {
        Task { [smc] in
            do { try await smc.setChargingAllowed(allowed); reply(true, nil) }
            catch { reply(false, "\(error)") }
        }
    }

    func setAdapterEnabled(_ enabled: Bool,
                           reply: @escaping @Sendable (Bool, String?) -> Void) {
        // 보안: 어댑터를 "끄는"(강제 방전) 동작은 정책상 강제 방전이 활성일 때만 허용.
        // 켜는(복원) 동작은 항상 허용.
        if !enabled && policy.forceDischargeTarget == nil {
            reply(false, "강제 방전이 비활성 상태라 어댑터 차단을 거부했습니다.")
            return
        }
        Task { [smc] in
            do {
                try await smc.setAdapterEnabled(enabled)
                self.setAdapterDisabledFlag(!enabled)
                reply(true, nil)
            } catch { reply(false, "\(error)") }
        }
    }

    func applyPolicy(_ data: Data,
                     reply: @escaping @Sendable (Bool, String?) -> Void) {
        do {
            let raw = try HelperPolicy.decoded(from: data)
            // 보안: 앱이 보낸 값을 무검증 사용하지 않는다 → 클램프 후 저장.
            self.policy = raw   // setter가 validated() 적용
            reply(true, nil)
        } catch {
            reply(false, "정책 디코딩 실패: \(error)")
        }
    }

    private func setAdapterDisabledFlag(_ v: Bool) {
        lock.lock(); _adapterDisabled = v; lock.unlock()
    }
    private var adapterDisabled: Bool {
        lock.lock(); defer { lock.unlock() }; return _adapterDisabled
    }

    func setSleepInhibit(_ enabled: Bool,
                         reply: @escaping @Sendable (Bool, String?) -> Void) {
        SleepWatcher.shared.setSleepInhibit(enabled)
        reply(true, nil)
    }

    func getDiagnostics(reply: @escaping @Sendable (Data?) -> Void) {
        Task { [smc] in
            let reading = await smc.readBattery()
            let data = try? JSONEncoder().encode(DiagnosticsDTO(reading: reading, policy: self.policy))
            reply(data)
        }
    }

    // MARK: 정책 적용 (SleepWatcher 등 내부 호출용)

    /// 보관된 정책 + 즉시 reading으로 충전/어댑터 상태를 한번 적용한다.
    /// 직전 상태를 영속화해 앱과 동일한 히스테리시스로 판단한다.
    func applyCurrentPolicy() async {
        let reading = await smc.readBattery()
        let p = policy
        let engine = ChargePolicyEngine()
        let state = engine.evaluate(.init(reading: reading, policy: p, previous: lastState))
        lastState = state

        let action = ChargeAction.from(state: state)
        try? await smc.setChargingAllowed(action.allowCharging)

        if p.forceDischargeTarget != nil {
            try? await smc.setAdapterEnabled(!action.forceDischarge)
            setAdapterDisabledFlag(action.forceDischarge)
        } else if adapterDisabled {
            // 강제 방전이 해제됐는데 어댑터가 꺼진 채면 반드시 복원(배터리 영구 방전 방지).
            try? await smc.setAdapterEnabled(true)
            setAdapterDisabledFlag(false)
        }
    }

    /// sleep 직전 동기 적용(기능 8). 콜백 스레드에서 짧게 블록해 IOAllowPowerChange 전에 완료시킨다.
    /// 타임아웃을 둬 sleep 전환을 무한정 막지 않는다.
    func applyChargingForSleepBlocking(timeout: TimeInterval = 2.0) {
        let p = policy
        guard !p.allowChargingWhileAsleep else { return }
        let sem = DispatchSemaphore(value: 0)
        Task { [smc] in
            // 수면 중 충전 금지 → 충전 차단.
            try? await smc.setChargingAllowed(false)
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + timeout)
    }

    /// 안전장치: 종료/복구 시 충전을 기본 허용 + 어댑터 복원.
    func restoreSafeDefaults() async {
        try? await smc.setChargingAllowed(true)
        if adapterDisabled {
            try? await smc.setAdapterEnabled(true)
            setAdapterDisabledFlag(false)
        }
    }
}

/// 진단용 직렬화 DTO.
private struct DiagnosticsDTO: Codable {
    let osChargePercent: Int?
    let hardwareChargePercent: Double?
    let temperatureCelsius: Double?
    let isCharging: Bool
    let isACPresent: Bool
    let chargeLimit: Int

    init(reading: BatteryReading, policy: HelperPolicy) {
        self.osChargePercent = reading.osChargePercent
        self.hardwareChargePercent = reading.hardwareChargePercent
        self.temperatureCelsius = reading.temperatureCelsius
        self.isCharging = reading.isCharging
        self.isACPresent = reading.isACPresent
        self.chargeLimit = policy.chargeLimit
    }
}
