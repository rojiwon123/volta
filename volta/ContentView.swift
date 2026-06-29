//
//  ContentView.swift
//  volta
//
//  메뉴바 팝오버 메인 화면. AlDente UX 참고: 충전 상한 슬라이더 + 상태/전력 + 토글.
//

import SwiftUI
import VoltaCore

struct ContentView: View {
    @Bindable var monitor: BatteryMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            // 능력(capability)별 노출: 능력 중 하나라도 쓸 수 있으면 컨트롤 영역을 보이고, 기능별로 가린다.
            // (충전 억제만 미작동이면 강제 방전만 남고, 어댑터 차단만 미작동이면 강제 방전만 가려진다.)
            // 전부 불가(미지원/헬퍼 없음/모든 능력 미작동)면 "기능 비활성화" 표시.
            if monitor.anyControlAvailable {
                // 점검 중에는 컨트롤을 잠근다(.disabled) — 점검이 제어를 직접 적용/복원하는 동안 사용자 변경 차단.
                Group {
                    if monitor.isFeatureAvailable(.chargeLimit) {
                        chargeLimitSection
                        Divider()
                    }
                    togglesSection
                    // 일부 능력만 미작동일 때 어떤 기능이 가려졌는지 안내.
                    if let note = monitor.partialDisabledNote {
                        Text(note).font(.caption2).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .disabled(monitor.selfTestRunning)
            } else {
                controlsDisabledPlaceholder
            }
            Divider()
            PowerFlowView(flow: PowerFlow.from(power: monitor.displayPower, isACPresent: monitor.displayACPresent))
            Divider()
            HelperStatusView(client: monitor.helper)
            // 점검(self-test): 헬퍼 상태 근처. 제어 가능할 때만 버튼 활성, 결과는 항상 표시.
            SelfTestView(monitor: monitor)
            if monitor.reading.cycleCount != nil || monitor.reading.batteryHealthPercent != nil {
                Divider()
                batteryInfoRow
            }
            #if DEBUG
            Divider()
            previewSection
            #endif
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 280)
        // ⚠️ 팝오버 열릴 때의 즉시 갱신은 여기(.task)서 하지 않는다 — 뷰 appear/레이아웃 패스 중에
        //    monitor 상태(reading/policyState/deviceSupport)를 변이시키면 조건부 행(온도·배터리정보·
        //    미지원 안내 등)으로 콘텐츠 높이가 바뀌고, NSHostingController가 그 레이아웃 도중 팝오버를
        //    리사이즈해 AppKit "layoutSubtreeIfNeeded ... already being laid out" 재귀 경고가 난다.
        //    → 갱신은 MenuBarController.togglePopover에서 표시 직후(레이아웃 패스 밖)로 미룬다.
    }

    // MARK: 헤더 — 현재 상태
    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: monitor.menuBarSymbol)
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("volta").font(.headline)
                // 메뉴바 아이콘과 동일 기준(menuBarState = 전력 흐름 기반, 과열만 예외)으로 표시.
                Text(monitor.menuBarState.localizedLabel)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(monitor.displayPercent.map { "\($0)%" } ?? "—")
                    .font(.title3).monospacedDigit()
                if let t = monitor.reading.temperatureCelsius {
                    Text(String(format: "%.1f℃", t))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: 제어 불가(모든 능력) 시 컨트롤 자리에 표시 — "기능 비활성화" + 사유(기기 미지원/모든 능력 미작동).
    // 헬퍼 미설치·미연결은 아래 HelperStatusView가 안내하므로 여기선 사유를 비운다(중복 방지).
    private var controlsDisabledPlaceholder: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("기능 비활성화").font(.subheadline).foregroundStyle(.secondary)
            if let reason = monitor.controlsDisabledReason {
                Text(reason)
                    .font(.caption2).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: 충전 제한(단일 상한) — max 한 값만 게이지로 조절
    private var chargeLimitSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("충전 제한").font(.subheadline)
                Spacer()
                Text("\(monitor.chargeLimit)%")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            ChargeLimitGauge(
                value: Binding(
                    get: { Double(monitor.chargeLimit) },
                    set: { monitor.chargeLimit = HelperPolicy.Bounds.limit.clamping(Int($0.rounded())) }
                ),
                bounds: HelperPolicy.Bounds.limit.doubleRange, step: 5
            )
            .frame(height: 24)
        }
    }

    // 사용 가능한 배터리 모드(없음 + 능력별 보조 모드). 강제 방전=어댑터 차단 능력, 외출 준비=충전 억제 능력.
    private var availableOverrideModes: [BatteryMonitor.OverrideMode] {
        var modes: [BatteryMonitor.OverrideMode] = [.none]
        if monitor.isFeatureAvailable(.forceDischarge) { modes.append(.forceDischarge) }
        if monitor.isFeatureAvailable(.tripPrep) { modes.append(.tripPrep) }
        return modes
    }

    // MARK: 토글 (기능 2·3·5·8) — 각 토글을 의존 능력별로 노출(능력 미작동이면 그 토글만 숨김).
    private var togglesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if monitor.isFeatureAvailable(.heatProtection) {
                Toggle("과열 보호(고온 시 충전·강제방전 중단)", isOn: $monitor.heatProtectionEnabled)
                if monitor.heatProtectionEnabled {
                    HStack {
                        Text("임계 온도").font(.subheadline)
                        Spacer()
                        Text("\(Int(monitor.heatCeiling))℃").monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: $monitor.heatCeiling, in: HelperPolicy.Bounds.ceiling, step: 1)
                }
            }
            if monitor.isFeatureAvailable(.sleepInhibit) {
                Toggle("상한 도달까지 잠자기 억제", isOn: $monitor.inhibitSleepUntilLimit)
            }
            if monitor.isFeatureAvailable(.sleepChargeStop) {
                // 수면 중 충전: 기본은 "중단(현재 잔량 유지)" — 앱이 자는 동안 상한에서 못 멈추니 과충전 방지.
                // 토글 ON(기본) = 중단·유지. OFF = 수면 중에도 상한까지 충전 허용(opt-in).
                Toggle("수면 중 충전 중단(현재 잔량 유지)", isOn: Binding(
                    get: { !monitor.allowChargingWhileAsleep },
                    set: { monitor.allowChargingWhileAsleep = !$0 }
                ))
            }
            // 배터리 모드 셀렉터 — 사용 가능한 모드만 노출(없음 + 강제방전?(어댑터 차단) + 외출준비?(충전 억제)).
            // 보조 모드가 하나도 없으면 셀렉터 자체를 숨긴다.
            let modes = availableOverrideModes
            if modes.count > 1 {
                Picker("배터리 모드", selection: Binding(
                    get: { monitor.overrideMode },
                    set: { monitor.overrideMode = $0 }
                )) {
                    ForEach(modes) { mode in
                        Text(mode.label).font(.caption).tag(mode)   // 라벨 폰트 한 단계 축소
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.large)              // 높이 약간 키워 누르기 편하게(과하지 않게)
                .frame(maxWidth: .infinity)       // 콘텐츠 폭 꽉 채움
            }
            if monitor.overrideMode == .forceDischarge, let target = monitor.forceDischargeTarget {
                HStack {
                    Text("방전 목표").font(.subheadline)
                    Spacer()
                    Text("\(target)%").monospacedDigit().foregroundStyle(.secondary)
                }
                ChargeLimitGauge(
                    value: Binding(
                        get: { Double(target) },
                        set: { monitor.forceDischargeTarget = Int($0.rounded()) }
                    ),
                    bounds: HelperPolicy.Bounds.dischargeTarget.doubleRange, step: 5
                )
                .frame(height: 24)
                if monitor.reading.isClamshellLikely {
                    Text("⚠️ 클램셸(덮개 닫힘) 상태에서는 강제 방전이 지원되지 않습니다.")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
        }
        .toggleStyle(.switch)
        .font(.subheadline)
    }

    #if DEBUG
    // MARK: 프리뷰 모드(디버그 전용) — 메뉴바 아이콘 강제 표시 테스트
    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("프리뷰 모드(메뉴바 강제 표시)", isOn: $monitor.previewEnabled)
                .toggleStyle(.switch)
            if monitor.previewEnabled {
                HStack {
                    Text("배터리").font(.subheadline)
                    Spacer()
                    Text("\(monitor.previewPercent)%").monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { Double(monitor.previewPercent) },
                        set: { monitor.previewPercent = Int($0) }
                    ),
                    in: 0...100, step: 1
                )
                Picker("상태", selection: $monitor.previewState) {
                    ForEach(ChargeState.allCases, id: \.self) { s in
                        Text(s.localizedLabel).tag(s)
                    }
                }
                .pickerStyle(.menu)
            }

            // 전력 흐름 시각 검증용 — 실 SMC와 무관하게 시나리오 강제
            Toggle("전력 프리뷰(흐름 시나리오)", isOn: $monitor.previewPowerEnabled)
                .toggleStyle(.switch)
            if monitor.previewPowerEnabled {
                Picker("시나리오", selection: $monitor.previewPowerScenario) {
                    ForEach(BatteryMonitor.PowerPreviewScenario.allCases) { sc in
                        Text(sc.label).tag(sc)
                    }
                }
                .pickerStyle(.menu)
            }
        }
        .font(.subheadline)
    }
    #endif

    // MARK: 배터리 정보(보조) — 사이클 수 + 수명(최대/설계 용량). 데이터 있을 때만.
    private var batteryInfoRow: some View {
        HStack(spacing: 10) {
            if let c = monitor.reading.cycleCount {
                Label("\(c)회", systemImage: "arrow.triangle.2.circlepath")
            }
            if let h = monitor.reading.batteryHealthPercent {
                Label(String(format: "수명 %.0f%%", h), systemImage: "heart.text.square")
            }
        }
        .font(.caption2).foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)
    }

    // MARK: 푸터
    private var footer: some View {
        HStack {
            if let hw = monitor.reading.hardwareChargePercent {
                Text(String(format: "HW %.1f%%", hw))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button("종료") { NSApplication.shared.terminate(nil) }
                .controlSize(.small)
        }
    }
}

// UI 컨트롤 범위를 정책 검증 범위(HelperPolicy.Bounds)와 한 곳에서 맞추기 위한 변환 헬퍼.
private extension ClosedRange where Bound == Int {
    var doubleRange: ClosedRange<Double> { Double(lowerBound)...Double(upperBound) }
    func clamping(_ v: Int) -> Int { Swift.min(Swift.max(v, lowerBound), upperBound) }
}

// MARK: - 충전 제한 게이지 (핸들 1개: 왼쪽부터 채워지는 게이지로 단일 상한 조절)

private struct ChargeLimitGauge: View {
    @Binding var value: Double
    let bounds: ClosedRange<Double>
    let step: Double

    private let knob: CGFloat = 18
    private let trackH: CGFloat = 8   // 게이지 느낌으로 다소 두껍게.

    var body: some View {
        GeometryReader { geo in track(geo.size) }
    }

    // ViewBuilder가 아닌 일반 메서드 — 지역 함수/return 사용 가능.
    private func track(_ size: CGSize) -> some View {
        let w = size.width, midY = size.height / 2
        let left = knob / 2, right = w - knob / 2, trackW = max(1, right - left)
        let span = max(bounds.upperBound - bounds.lowerBound, 0.0001)
        func cx(_ v: Double) -> CGFloat { left + CGFloat((v - bounds.lowerBound) / span) * trackW }
        func snapped(at x: CGFloat) -> Double {
            let t = min(max(Double((x - left) / trackW), 0), 1)
            return ((bounds.lowerBound + t * span) / step).rounded() * step
        }
        return ZStack {
            Capsule().fill(Color.secondary.opacity(0.25))
                .frame(width: trackW, height: trackH).position(x: w / 2, y: midY)
            // 게이지 채움: 왼쪽 끝부터 현재 상한까지.
            Capsule().fill(Color.accentColor)
                .frame(width: max(2, cx(value) - left), height: trackH)
                .position(x: (left + cx(value)) / 2, y: midY)
            knobView.position(x: cx(value), y: midY)
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("clg"))
                    .onChanged { g in value = min(max(snapped(at: g.location.x), bounds.lowerBound), bounds.upperBound) })
        }
        .coordinateSpace(name: "clg")
    }

    private var knobView: some View {
        Circle().fill(.white)
            .overlay(Circle().strokeBorder(Color.secondary.opacity(0.35), lineWidth: 0.5))
            .frame(width: knob, height: knob)
            .shadow(color: .black.opacity(0.25), radius: 1.5, x: 0, y: 1)
    }
}
