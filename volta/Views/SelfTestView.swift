//
//  SelfTestView.swift
//  volta
//
//  "점검(self-test)" UI. 헬퍼 상태 근처에 두는 최소 디자인 — 버튼 한 개 + 진행 표시 + 단계별 결과.
//  실제 점검(라이브 적용/관찰/복원)은 BatteryMonitor.runSelfTest()가 수행한다. 이 뷰는 트리거·표시만.
//

import SwiftUI
import VoltaCore

struct SelfTestView: View {
    @Bindable var monitor: BatteryMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("점검").font(.subheadline)
                Spacer()
                if monitor.selfTestRunning {
                    ProgressView().controlSize(.small)
                    Text("점검 중…").font(.caption).foregroundStyle(.secondary)
                } else {
                    Button("점검") { Task { await monitor.runSelfTest() } }
                        .controlSize(.small)
                        .disabled(!monitor.isControlSupported)
                }
            }

            if let msg = monitor.selfTestMessage {
                Text(msg)
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(monitor.selfTestResults) { result in
                HStack(spacing: 6) {
                    Image(systemName: result.outcome.symbolName)
                        .font(.caption2).foregroundStyle(result.outcome.tint)
                    Text(result.step.label).font(.caption)
                    Spacer()
                    Text(result.outcome.statusLabel)
                        .font(.caption2).foregroundStyle(result.outcome.tint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !monitor.selfTestResults.isEmpty {
                // ACLC(충전 LED)는 시각 검증이라 자동 판정에서 제외 — 수동 확인 안내.
                Text("· 충전 LED는 눈으로 확인하세요(자동 판정 제외).")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

// SwiftUI 표시(색/심볼/라벨)는 앱 계층에서만 — VoltaCore 순수 타입은 UI를 모른다.
private extension SelfTestOutcome {
    var statusLabel: String {
        switch self {
        case .working:                 return "동작함"
        case .notWorking:              return "동작 안 함"
        case .undetermined(let reason): return "판정 불가: \(reason)"
        }
    }
    var symbolName: String {
        switch self {
        case .working:      return "checkmark.circle.fill"
        case .notWorking:   return "xmark.circle.fill"
        case .undetermined: return "questionmark.circle"
        }
    }
    var tint: Color {
        switch self {
        case .working:      return .green
        case .notWorking:   return .red
        case .undetermined: return .orange
        }
    }
}
