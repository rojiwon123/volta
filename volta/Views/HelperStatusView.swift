//
//  HelperStatusView.swift
//  volta
//
//  헬퍼 데몬 등록/승인 상태 표시 및 액션(기능 1·3·8의 전제).
//

import SwiftUI

struct HelperStatusView: View {
    @Bindable var client: HelperClient

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.caption)
            Spacer()
            action
        }
    }

    private var color: Color {
        switch client.status {
        case .enabled: return .green
        case .requiresApproval: return .orange
        case .notRegistered: return .gray
        case .failed: return .red
        }
    }

    private var label: String {
        switch client.status {
        case .enabled: return "헬퍼 활성"
        case .requiresApproval: return "승인 필요"
        case .notRegistered: return "헬퍼 미등록"
        case .failed(let m): return "오류: \(m)"
        }
    }

    @ViewBuilder private var action: some View {
        switch client.status {
        case .requiresApproval:
            Button("승인 열기") { client.openSystemSettingsForApproval() }
                .controlSize(.small)
        case .notRegistered, .failed:
            Button("설치") { client.registerIfNeeded() }
                .controlSize(.small)
        case .enabled:
            EmptyView()
        }
    }
}
