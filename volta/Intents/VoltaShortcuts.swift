//
//  VoltaShortcuts.swift
//  volta
//
//  기능 7: Apple Shortcuts(App Intents). 인텐트는 in-process로 실행되어
//  BatteryMonitor.shared 를 통해 정책을 변경/조회한다.
//
//  App Intents 메타데이터는 Xcode가 빌드 시 자동 추출한다(별도 빌드 단계 불필요).
//

import AppIntents
import Foundation
import VoltaCore

// MARK: 충전 상한 설정

struct SetChargeLimitIntent: AppIntent {
    static let title: LocalizedStringResource = "충전 상한 설정"
    static let description = IntentDescription("배터리 충전 상한(%)을 설정합니다.")

    @Parameter(title: "상한(%)", inclusiveRange: (50, 100))
    var limit: Int

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        BatteryMonitor.shared.chargeLimit = limit
        return .result(dialog: "충전 상한을 \(limit)%로 설정했어요.")
    }
}

// MARK: 과열 보호 토글

struct SetHeatProtectionIntent: AppIntent {
    static let title: LocalizedStringResource = "과열 보호 설정"

    @Parameter(title: "켜기")
    var enabled: Bool

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        BatteryMonitor.shared.heatProtectionEnabled = enabled
        return .result(dialog: enabled ? "과열 보호를 켰어요." : "과열 보호를 껐어요.")
    }
}

// MARK: 강제 방전

struct StartDischargeIntent: AppIntent {
    static let title: LocalizedStringResource = "강제 방전 시작"
    static let description = IntentDescription("지정 목표(%)까지 배터리를 방전합니다.")

    @Parameter(title: "목표(%)", inclusiveRange: (10, 95))
    var target: Int

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        BatteryMonitor.shared.forceDischargeTarget = target
        return .result(dialog: "\(target)%까지 방전을 시작했어요.")
    }
}

struct StopDischargeIntent: AppIntent {
    static let title: LocalizedStringResource = "강제 방전 중지"

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        BatteryMonitor.shared.forceDischargeTarget = nil
        return .result(dialog: "강제 방전을 중지했어요.")
    }
}

// MARK: 상태 조회

struct GetBatteryStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "배터리 상태 보기"

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<Int> {
        let m = BatteryMonitor.shared
        let pct = m.displayPercent ?? 0
        return .result(value: pct, dialog: "현재 \(pct)%, 상태: \(m.policyState.localizedLabel).")
    }
}

// MARK: AppShortcutsProvider

struct VoltaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SetChargeLimitIntent(),
            phrases: ["\(.applicationName) 충전 상한 설정"],
            shortTitle: "충전 상한 설정",
            systemImageName: "battery.75"
        )
        AppShortcut(
            intent: StartDischargeIntent(),
            phrases: ["\(.applicationName) 강제 방전"],
            shortTitle: "강제 방전",
            systemImageName: "battery.25"
        )
        AppShortcut(
            intent: GetBatteryStatusIntent(),
            phrases: ["\(.applicationName) 배터리 상태"],
            shortTitle: "배터리 상태",
            systemImageName: "bolt.fill"
        )
    }
}
