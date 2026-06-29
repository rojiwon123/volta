//
//  BatteryMonitor.swift
//  volta (app)
//
//  앱의 중심 모델. SMC 읽기(VoltaCore.SMCService) + 정책 판단(ChargePolicyEngine)을 묶고,
//  결정된 동작을 HelperClient(XPC)로 헬퍼에 위임한다. UI는 이 @Observable을 관찰한다.
//
//  ⚠️ 앱 타깃은 VoltaCore 패키지 링크 필요(Xcode 연결 — docs 참조).
//

import Foundation
import Observation
import VoltaCore

@MainActor
@Observable
final class BatteryMonitor {

    // MARK: 공개 상태(UI 바인딩)
    private(set) var reading: BatteryReading = .unknown
    private(set) var policyState: ChargeState = .suspended

    let helper = HelperClient()

    /// 기기 지원 판정(capability gating). Apple Silicon + allowlist 모델만 제어 활성.
    /// 미지원이면 SMC 쓰기는 SMCService에서 no-op이고, UI는 제어 기능을 비활성/안내한다.
    /// **런타임 강등 가능**: write 후 효과 미관찰 시 `.ineffective`로 내려가 제어가 비활성된다.
    private(set) var deviceSupport: DeviceSupportResult = DeviceSupport.current
    /// 제어를 실제로 쓸 수 있는지 — 기기 지원(allowsSMCWrites) **그리고** 헬퍼가 실제 연결돼 응답할 때만.
    /// 헬퍼 판정은 등록 status(.enabled, "등록 의도"라 데몬 미로드여도 true일 수 있음)가 아니라
    /// **실제 XPC 핑 성공(isReachable)** 으로 한다. 미지원/`.ineffective`/헬퍼 미설치·미연결·미응답 등
    /// "제어 불가" 모든 상태에서 false → UI가 컨트롤을 숨기고 "기능 비활성화" 안내.
    var isControlSupported: Bool { deviceSupport.allowsSMCWrites && helper.isReachable }

    // MARK: 사용자 설정(영구 저장)
    var chargeLimit: Int {
        didSet { settingsChanged() }
    }
    var heatProtectionEnabled: Bool {
        didSet { settingsChanged() }
    }
    /// 과열 보호 임계 온도(℃). 엔진 heatProtectionCeiling으로 전달(검증 시 30~60 클램프).
    var heatCeiling: Double {
        didSet { settingsChanged() }
    }
    /// 수면 중 충전 허용. 기본 false = 수면 시 충전 중단(현재 잔량 유지, 과충전 방지). true면 opt-in 허용.
    var allowChargingWhileAsleep: Bool {
        didSet { settingsChanged() }
    }
    var inhibitSleepUntilLimit: Bool {
        didSet { settingsChanged() }
    }
    /// 강제 방전 목표(nil=비활성). 기능 3. **외출 준비와 상호 배타** — 켜면 외출 준비를 끈다.
    var forceDischargeTarget: Int? {
        didSet {
            if forceDischargeTarget != nil, tripPrepEnabled {
                suppressSettingsSideEffects = true
                tripPrepEnabled = false
                suppressSettingsSideEffects = false
            }
            settingsChanged()
        }
    }
    /// 외출 준비(수동 100% 풀충전 오버라이드). **강제 방전과 상호 배타** — 켜면 강제 방전을 끈다.
    var tripPrepEnabled: Bool {
        didSet {
            if tripPrepEnabled, forceDischargeTarget != nil {
                suppressSettingsSideEffects = true
                forceDischargeTarget = nil
                suppressSettingsSideEffects = false
            }
            settingsChanged()
        }
    }
    /// 상호 배타 처리 중 내부 cross-set이 settingsChanged를 중복 실행하지 않도록 하는 가드.
    private var suppressSettingsSideEffects = false

    /// UI 3택 셀렉터(없음 / 강제 방전 / 외출 준비). 상호 배타는 셀렉터 구조 + 아래 setter로 보장.
    /// 내부 source of truth는 forceDischargeTarget·tripPrepEnabled 그대로(엔진/헬퍼/저장은 그 둘만 본다).
    enum OverrideMode: String, CaseIterable, Identifiable {
        case none, forceDischarge, tripPrep
        var id: String { rawValue }
        var label: String {
            switch self {
            case .none:          return "없음"
            case .forceDischarge: return "강제 방전"
            case .tripPrep:      return "외출 준비"
            }
        }
    }

    /// 강제 방전 토글의 기본 목표(%).
    static let defaultForceDischargeTarget = 50

    var overrideMode: OverrideMode {
        get {
            if tripPrepEnabled { return .tripPrep }
            if forceDischargeTarget != nil { return .forceDischarge }
            return .none
        }
        set {
            switch newValue {
            case .none:
                if forceDischargeTarget != nil { forceDischargeTarget = nil }
                if tripPrepEnabled { tripPrepEnabled = false }
            case .forceDischarge:
                // 기존 목표가 있으면 유지, 없으면 기본값. (didSet이 외출 준비를 끈다.)
                forceDischargeTarget = forceDischargeTarget ?? Self.defaultForceDischargeTarget
            case .tripPrep:
                tripPrepEnabled = true   // didSet이 강제 방전을 끈다.
            }
        }
    }

    private let smc = SMCService()
    private let engine = ChargePolicyEngine()
    private var pollTask: Task<Void, Never>?
    private let pollInterval: Duration = .seconds(10)

    // 적용 상태 추적(중복 SMC 쓰기 방지 + 주기적 재적용).
    private var appliedChargingAllowed: Bool?
    private var appliedAdapterEnabled: Bool?
    private var appliedSleepInhibit: Bool?
    private var reassertCounter = 0
    /// N틱마다 상태 변화가 없어도 SMC를 재적용(외부 리셋 대비). 10틱 ≈ 100초.
    private let reassertEvery = 10

    // MARK: 효과 검증(행동 기반) — 제어 적용 후 거동이 바뀌는지 확인, 미관찰 시 런타임 강등.
    /// 세션당 제어 유형별 1회만 검증(먹으면 재검증 불필요, 안 먹으면 강등 sticky).
    private var verifiedChargeInhibit = false
    private var verifiedAdapterDisable = false
    /// 정착 지연 + 샘플 수/간격. (실시간 지연 — 판정 로직 자체는 VoltaCore 순수 함수로 단위 테스트.)
    private let effectSettleDelay: Duration = .seconds(15)
    private let effectSampleCount = 3
    private let effectSampleInterval: Duration = .seconds(5)
    #if DEBUG
    private var lastDiagLog: String?   // 진단 로그 중복 억제(값 변화 시에만 출력).
    #endif

    /// App Intents 등 in-process 비-View 코드에서 접근하기 위한 공유 인스턴스.
    static let shared = BatteryMonitor()

    // MARK: 초기화 (설정 로드)
    init() {
        let d = UserDefaults.standard
        self.chargeLimit = d.object(forKey: K.limit) as? Int ?? 80
        self.heatProtectionEnabled = d.object(forKey: K.heat) as? Bool ?? true
        self.heatCeiling = d.object(forKey: K.heatCeiling) as? Double ?? 40.0
        self.allowChargingWhileAsleep = d.object(forKey: K.sleepCharge) as? Bool ?? false
        self.inhibitSleepUntilLimit = d.object(forKey: K.inhibit) as? Bool ?? false
        self.forceDischargeTarget = d.object(forKey: K.discharge) as? Int
        self.tripPrepEnabled = d.object(forKey: K.tripPrep) as? Bool ?? false
        // 저장값이 모순(둘 다 활성)이면 안전 우선으로 외출 준비를 끈다(엔진 validated와 동일 규칙).
        if self.tripPrepEnabled, self.forceDischargeTarget != nil { self.tripPrepEnabled = false }
    }

    // MARK: 수명주기

    func start() {
        helper.registerIfNeeded()
        Task { _ = await helper.pushPolicy(currentPolicy()) }
        pollTask?.cancel()
        let interval = pollInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        Task { await smc.shutdown() }
    }

    /// 한 사이클: 읽기 → 상태 판단 → (변화 또는 주기적으로) 헬퍼에 적용.
    func tick() async {
        let r = await smc.readBattery()
        self.reading = r

        // 헬퍼 실제 연결 여부(핑) 갱신 — isControlSupported가 이 값을 신뢰 신호로 본다.
        // 폴링 루프(타이머)에서만 갱신되므로 isControlSupported 변화(→ 컨트롤↔플레이스홀더 전환)는
        // 레이아웃 패스 밖에서 일어나 재귀를 유발하지 않는다.
        await helper.ping()
        #if DEBUG
        // 진단: 값이 바뀔 때만 1줄(매 tick 노이즈 방지). status(.enabled, 등록 의도)와 isReachable(실제 연결)의
        // 괴리를 추적하기 좋다 — 데몬 미로드여도 status=.enabled로 뜨던 게 과거 오탐 원인이었다.
        let logState = "status=\(helper.status) reachable=\(helper.isReachable) controlSupported=\(isControlSupported)"
        if logState != lastDiagLog { lastDiagLog = logState; print("[volta] \(logState)") }
        #endif

        // 강제 방전 1회성 완료(SoC ≤ 목표) → 자동 해제(off). 이후 충전 제한 정책으로 복귀해
        // 전력 연결 시 max까지 충전된다(무한 방전↔충전 루프 방지). didSet이 저장/헬퍼 푸시까지 처리.
        if forceDischargeTarget != nil, engine.isForceDischargeComplete(reading: r, policy: currentPolicy()) {
            forceDischargeTarget = nil
        }

        let next = engine.evaluate(.init(reading: r, policy: currentPolicy(), previous: policyState))
        let changed = next != policyState
        self.policyState = next

        reassertCounter += 1
        let mustReassert = reassertCounter >= reassertEvery
        if mustReassert { reassertCounter = 0 }
        guard changed || mustReassert else { return }

        let action = ChargeAction.from(state: next)
        // 런타임 강등(.ineffective)/미지원이면 제어를 비활성하고 **안전 상태로 수렴**:
        // 충전 허용 + 어댑터 정상 + 억제 없음. (제어가 이 기기에서 안 먹으므로 더 시도하지 않는다.)
        let controlOn = isControlSupported
        let wantAllowCharging = controlOn ? action.allowCharging : true
        // 어댑터 목표: 강제 방전 활성 시 의도대로, 비활성 시 항상 복원(켜짐) 보장.
        let wantAdapterEnabled = controlOn ? (forceDischargeTarget != nil ? !action.forceDischarge : true) : true
        // 수면 억제(sleep inhibit): ① 기능 7(상한까지 억제 토글+충전) ② 기능 5(강제방전/외출준비 작동 중).
        let overrideSleepPrevent = engine.shouldPreventSleepForOverride(reading: r, policy: currentPolicy())
        let wantInhibit = controlOn ? ((inhibitSleepUntilLimit && next == .charging) || overrideSleepPrevent) : false

        // 헬퍼가 enabled가 아니면(미설치/미연결) 잘못된 런타임 강등(.ineffective)을 자동 해제 —
        // 헬퍼 없으면 write가 안 일어나 "효과 미관찰" 단정 불가. 헬퍼 부재는 HelperStatusView로만 표시.
        deviceSupport = deviceSupport.clearedIfControlWriteUnavailable(
            helperEnabled: helper.status == .enabled, base: DeviceSupport.current)

        // 직전 적용값(검증 트리거의 "신규 적용" 판정용).
        let wasChargingAllowed = appliedChargingAllowed
        let wasAdapterEnabled = appliedAdapterEnabled

        // 변경이 있을 때만 SMC 쓰기(또는 주기적 재적용 시). 반환값 = **헬퍼가 실제 write를 수행했는지**
        // (미연결/실패면 false) — 효과 검증은 이 성공 신호가 있을 때만 돈다.
        var chargeWritePerformed = false
        if appliedChargingAllowed != wantAllowCharging || mustReassert {
            if await helper.setChargingAllowed(wantAllowCharging) {
                appliedChargingAllowed = wantAllowCharging
                chargeWritePerformed = true
            }
        }
        var adapterWritePerformed = false
        if appliedAdapterEnabled != wantAdapterEnabled || mustReassert {
            if await helper.setAdapterEnabled(wantAdapterEnabled) {
                appliedAdapterEnabled = wantAdapterEnabled
                adapterWritePerformed = true
            }
        }
        if appliedSleepInhibit != wantInhibit {
            if await helper.setSleepInhibit(wantInhibit) {
                appliedSleepInhibit = wantInhibit
            }
        }

        // 효과 검증 트리거: **헬퍼로 write가 실제 수행(성공)된 경우에만** + 세션 첫 신규 적용. before=r.
        // (write 미수행 = 헬퍼 미설치/미연결 → 검증·강등 안 함 → "효과 미관찰" 오탐 방지.)
        if !verifiedChargeInhibit, wantAllowCharging == false, wasChargingAllowed != false,
           ControlEffectVerifier.shouldVerify(writePerformed: chargeWritePerformed, controlSupported: controlOn) {
            verifiedChargeInhibit = true
            scheduleEffectVerification(intent: .chargeInhibited, before: r)
        }
        if !verifiedAdapterDisable, wantAdapterEnabled == false, wasAdapterEnabled != false,
           ControlEffectVerifier.shouldVerify(writePerformed: adapterWritePerformed, controlSupported: controlOn) {
            verifiedAdapterDisable = true
            scheduleEffectVerification(intent: .adapterDisabled, before: r)
        }
    }

    // MARK: 효과 검증 오케스트레이션(행동 기반) + 런타임 강등·안전 수렴

    /// 제어 적용 후 정착 지연 + 수 틱 샘플링 → 거동 판정. 미관찰(.notObserved)이면 강등+안전 수렴.
    /// fire-and-forget(폴링 루프를 막지 않음). 판정 로직은 VoltaCore 순수 함수(단위 테스트).
    private func scheduleEffectVerification(intent: ControlIntent, before: BatteryReading) {
        Task { [weak self] in await self?.runEffectVerification(intent: intent, before: before) }
    }

    private func runEffectVerification(intent: ControlIntent, before: BatteryReading) async {
        guard isControlSupported else { return }
        try? await Task.sleep(for: effectSettleDelay)   // 정착(SMC/OS 반영 시간차) — 즉시 판정 금지.
        var after: [BatteryReading] = []
        for _ in 0..<effectSampleCount {
            after.append(await smc.readBattery())
            try? await Task.sleep(for: effectSampleInterval)
        }
        let effect = smc.verifyControlEffect(intent: intent, before: before, after: after)
        guard effect == .notObserved else { return }   // observed/inconclusive → 강등 안 함.

        // write됐는데 거동 안 바뀜 → 이 기기에서 제어 미작동으로 판단: 런타임 강등 + 안전 수렴.
        let reason = (intent == .chargeInhibited) ? "충전 억제 미반영" : "어댑터 차단(강제 방전) 미반영"
        deviceSupport = deviceSupport.applyingControlEffect(.notObserved, reason: reason)
        await convergeToSafeState()
    }

    /// 안전 상태로 수렴: 충전 허용 + 어댑터 정상 + 억제 해제 + 강제방전/외출준비 해제.
    private func convergeToSafeState() async {
        if await helper.setChargingAllowed(true) { appliedChargingAllowed = true }
        if await helper.setAdapterEnabled(true) { appliedAdapterEnabled = true }
        if appliedSleepInhibit == true, await helper.setSleepInhibit(false) { appliedSleepInhibit = false }
        if forceDischargeTarget != nil { forceDischargeTarget = nil }
        if tripPrepEnabled { tripPrepEnabled = false }
    }

    /// 팝오버 헤더의 배터리 심볼. 메뉴바 아이콘과 **동일 기준**(menuBarState = 전력 흐름 기반,
    /// 과열만 예외)으로 그려 헤더·메뉴바·전력 흐름이 항상 일치한다. (이 값을 쓰는 곳은 헤더뿐이다.)
    var menuBarSymbol: String {
        switch menuBarState {
        case .charging:        return "battery.100.bolt"
        case .limitReached:    return "battery.75"
        case .discharging:     return "battery.50"
        case .forcedDischarge: return "battery.25"   // menuBarState는 이 값을 내지 않으나 exhaustive 위해 유지
        case .heatPaused:      return "thermometer.high"
        case .suspended:       return "battery.100"
        }
    }

    /// UI 표시용 충전 비율(하드웨어 우선).
    var displayPercent: Int? {
        engine.effectiveChargePercent(reading)
    }

    // MARK: 메뉴바 표시 소스(프리뷰 인식)
    // 메뉴바(MenuBarController)는 아래 두 값을 읽는다. 릴리스 빌드에서는
    // 실제 policyState/displayPercent 그대로이며 프리뷰 흔적이 남지 않는다.

    /// 메뉴바가 그릴 상태. 프리뷰 모드 ON이면 강제값.
    /// 그 외엔 **전력 흐름(PowerFlowView)과 동일한 기준**으로만 그린다 — 같은 입력
    /// (displayPower·displayACPresent)을 `PowerFlow`에 넣어 얻은 activity로 분류하므로
    /// 아이콘과 흐름이 항상 일치한다. 강제 방전·외출 준비·충전 제한 같은 '기능 설정'은
    /// 분류를 직접 좌우하지 않고, 그 기능들이 만든 결과적 전력 흐름으로만 (충전/유지/방전) 그려진다.
    /// 유일한 예외는 **과열 보호(heatPaused)** — 흐름에 안 드러나므로 우선 표시.
    /// 데이터 없음(suspended)도 흐름 이전 단계라 우선 처리.
    var menuBarState: ChargeState {
        #if DEBUG
        if previewEnabled { return previewState }
        #endif
        if displayPercent == nil { return .suspended }
        if policyState == .heatPaused { return .heatPaused }
        switch PowerFlow.from(power: displayPower, isACPresent: displayACPresent).activity {
        case .charging:    return .charging
        case .discharging: return .discharging              // 방전은 원인·기능 무관하게 동일(잔량 글리프)
        case .holding:     return .limitReached             // AC 유지/bypass: pause
        case .idle:        return displayACPresent ? .limitReached : .discharging
        }
    }

    /// 메뉴바가 그릴 충전 %. 프리뷰 모드 ON이면 강제값, 아니면 실제 표시값.
    var menuBarPercent: Int? {
        #if DEBUG
        if previewEnabled { return previewPercent }
        #endif
        return displayPercent
    }

    // MARK: 팝오버 전력 표시 소스(프리뷰 인식)
    /// 팝오버 전력 흐름이 쓸 전력 메트릭. 전력 프리뷰 ON이면 시나리오 강제값, 아니면 실측.
    var displayPower: PowerMetrics {
        #if DEBUG
        if previewPowerEnabled { return previewPowerScenario.metrics }
        #endif
        return reading.power
    }
    /// 팝오버 전력 흐름이 쓸 AC 연결 여부(프리뷰 인식).
    var displayACPresent: Bool {
        #if DEBUG
        if previewPowerEnabled { return previewPowerScenario.acPresent }
        #endif
        return reading.isACPresent
    }

    #if DEBUG
    // MARK: 프리뷰 모드(디버그 전용)
    // 실제 SMC/폴링과 무관하게 메뉴바/전력 표시만 강제로 덮어쓴다(읽기 가로채기).
    // @Observable 저장 프로퍼티라 값 변경 시 즉시 다시 그려진다.

    /// ON일 때만 previewPercent/previewState가 메뉴바에 적용. OFF면 실제 값으로 복귀.
    var previewEnabled = false
    /// 강제 배터리 %(0~100).
    var previewPercent = 80
    /// 강제 ChargeState.
    var previewState: ChargeState = .charging

    /// ON이면 팝오버 전력 흐름이 previewPowerScenario 강제값을 쓴다.
    var previewPowerEnabled = false
    /// 전력 흐름 시각 검증용 시나리오.
    var previewPowerScenario: PowerPreviewScenario = .dischargeMix

    /// 전력 프리뷰 시나리오(어댑터만/충전/방전혼합/배터리만/거의없음). 시각 작업·검증용 샘플.
    enum PowerPreviewScenario: String, CaseIterable, Identifiable {
        case adapterOnly, charging, dischargeMix, batteryOnly, idle
        var id: String { rawValue }
        var label: String {
            switch self {
            case .adapterOnly:  return "어댑터만(배터리 0)"
            case .charging:     return "충전(어댑터→배터리)"
            case .dischargeMix: return "방전 혼합(고부하)"
            case .batteryOnly:  return "배터리만(AC 미연결)"
            case .idle:         return "거의 없음(소스 숨김)"
            }
        }
        /// 부호 규약: 배터리 양수=충전, 음수=방전 (PowerFlow와 동일 가정).
        var metrics: PowerMetrics {
            switch self {
            case .adapterOnly:  return .init(adapterWatts: 30,  batteryWatts: 0,     systemWatts: 30,   adapterRatedWatts: 96)
            case .charging:     return .init(adapterWatts: 36,  batteryWatts: 15.5,  systemWatts: 20.2, adapterRatedWatts: 96)  // 배터리=우측 sink
            case .dischargeMix: return .init(adapterWatts: 28,  batteryWatts: -33,   systemWatts: 61,   adapterRatedWatts: 96)
            case .batteryOnly:  return .init(adapterWatts: nil, batteryWatts: -20,   systemWatts: 20,   adapterRatedWatts: nil) // AC 미연결
            case .idle:         return .init(adapterWatts: 0.2, batteryWatts: 0.1,   systemWatts: 3,    adapterRatedWatts: 96)
            }
        }
        var acPresent: Bool { self != .batteryOnly }
    }
    #endif

    // MARK: 정책 구성/저장

    func currentPolicy() -> HelperPolicy {
        HelperPolicy(
            chargeLimit: chargeLimit,
            heatProtectionCeiling: heatProtectionEnabled ? heatCeiling : nil,
            forceDischargeTarget: forceDischargeTarget,
            tripPrepEnabled: tripPrepEnabled,
            allowChargingWhileAsleep: allowChargingWhileAsleep,
            inhibitSleepUntilLimit: inhibitSleepUntilLimit
        )
    }

    private func settingsChanged() {
        if suppressSettingsSideEffects { return }   // 상호 배타 cross-set 중 중복 실행 방지.
        let d = UserDefaults.standard
        d.set(chargeLimit, forKey: K.limit)
        d.set(heatProtectionEnabled, forKey: K.heat)
        d.set(heatCeiling, forKey: K.heatCeiling)
        d.set(allowChargingWhileAsleep, forKey: K.sleepCharge)
        d.set(inhibitSleepUntilLimit, forKey: K.inhibit)
        if let t = forceDischargeTarget { d.set(t, forKey: K.discharge) }
        else { d.removeObject(forKey: K.discharge) }
        d.set(tripPrepEnabled, forKey: K.tripPrep)
        // 구버전 dischargeFloor(밴드 min) 설정은 단일 상한 모델로 전환되며 더 이상 쓰지 않는다(잔존 키는 무시).
        // 변경 즉시 헬퍼에 사전 푸시(기능 8) + 한 사이클 적용.
        Task {
            _ = await helper.pushPolicy(currentPolicy())
            await tick()
        }
    }

    private enum K {
        static let limit = "volta.chargeLimit"
        static let heat = "volta.heatProtection"
        static let sleepCharge = "volta.allowChargingWhileAsleep"
        static let inhibit = "volta.inhibitSleepUntilLimit"
        static let heatCeiling = "volta.heatCeiling"
        static let discharge = "volta.forceDischargeTarget"
        static let tripPrep = "volta.tripPrepEnabled"
    }
}
