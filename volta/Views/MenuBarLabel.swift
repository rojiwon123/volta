//
//  MenuBarLabel.swift
//  volta
//
//  메뉴바 아이콘 한 곳. MenuBarController가 ImageRenderer로 래스터화해 NSStatusItem(template)에 넣는다.
//  레이아웃: HStack[ %텍스트 | 아이콘 ].  아이콘 z-순서: 배터리 → halo(둘레 도려내기) → 배지.
//
//  크기: 메뉴바 높이는 시스템이 바 두께로 고정한다(OS 한계). 그래서 캔버스 높이를 barHeight(바 두께)에
//        고정하고, 그 안에서 배터리/%/배지를 "바 대비 비율"(노브 3개)로 그린다.
//  색·알파: isTemplate라 색은 시스템이 라이트/다크 적응색으로 덮고 "알파만" 마스크로 쓴다. 그래서
//        모든 잉크는 .black(투명도만 차이)로 그리고, 배터리 "테두리(rim)"만 rimOpacity로 반투명,
//        채움·번개·배지·%는 불투명(alpha 1)으로 둔다. (native 배터리처럼 테두리만 살짝 비침.)
//

import AppKit
import SwiftUI
import VoltaCore

struct MenuBarLabel: View {

    let state: ChargeState
    let percent: Int?          // 표시용 충전%(하드웨어 우선). nil이면 데이터 없음.

    // MARK: 조정 노브 (바 두께 대비 비율) — 보통 이 3개만 만진다
    private let batterySizeRatio: CGFloat = 0.8    // 배터리 글리프 크기 ÷ 바 높이.   권장 0.9~1.6
    private let percentFontRatio: CGFloat = 0.55   // % 글자 크기 ÷ 바 높이.          권장 0.45~0.65
    private let badgeRatio:       CGFloat = 0.7    // 배지 정사각 한 변 ÷ 배터리 크기.  권장 0.5~0.8

    // MARK: 디자인 미세값 (노브 아님 — 보통 안 만짐)
    private let rimOpacity:          Double  = 0.7    // 배터리 테두리(rim) 반투명도. native처럼 테두리만 살짝 비침
    private let terminalOffsetRatio: CGFloat = 0.09   // 배지를 단자(오른쪽 돌출)폭만큼 왼쪽으로 → 본체 가로 중앙
    private let haloRatio:           CGFloat = 0.15   // 배지 둘레 투명 간격: 배지보다 이만큼 큰 실루엣으로 도려냄

    // MARK: 파생 크기
    private var barHeight: CGFloat { max(12, NSStatusBar.system.thickness) }   // 캔버스 높이 = 바 두께(얇은 바 12pt 하한)
    private var basePointSize: CGFloat { barHeight * batterySizeRatio }
    private var percentFontSize: CGFloat { barHeight * percentFontRatio }

    var body: some View {
        HStack(spacing: 3) {   // "숫자 → 아이콘" 순(macOS 기본 배터리와 동일)
            if showsPercent, let percent {
                Text("\(percent)%")
                    .font(.system(size: percentFontSize, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.black)
            }
            glyph
        }
        .frame(height: barHeight)   // 이미지 높이를 바 두께에 고정 → status item이 더 클램프(축소)하지 않음
        .clipped()
    }

    private var showsPercent: Bool { percent != nil && state != .suspended }

    // MARK: 아이콘 = 배터리(베이스) + (선택) 배지, 둘레 halo 분리
    //
    // ⚠️ 배터리 렌더는 반드시 이 안에 "인라인"으로 둔다. SwiftUI에서 @ViewBuilder 헬퍼 함수로 빼면
    //    배터리 palette의 부분 알파(rim 0.7)가 1.0으로 평탄화되는 이슈가 있다(실측 확인). 배지(불투명)는
    //    헬퍼로 빼도 안전.
    private var glyph: some View {
        let spec = glyphSpec
        // 테두리(rim)만 rimOpacity. rim의 palette 레이어 인덱스가 변형마다 다름(실측):
        //   battery.0(빈배터리)=primary / battery.NN·battery.100.bolt=secondary.
        let rim = Color.black.opacity(rimOpacity)
        let onEmpty = (spec.base == Symbols.emptyBattery)
        let primary:   Color = onEmpty ? rim : .black     // 빈배터리는 rim=primary, 그 외엔 채움/번개=primary(불투명)
        let secondary: Color = onEmpty ? .black : rim     // 그 외엔 rim=secondary
        let badgeX = -basePointSize * terminalOffsetRatio

        return ZStack {
            Image(systemName: spec.base)               // 포인트 크기 렌더 → 변형 무관 본체 정렬
                .font(.system(size: basePointSize))
                .symbolRenderingMode(.palette)
                .foregroundStyle(primary, secondary, .black)   // tertiary(채움)=불투명
            if let badge = spec.badge {
                // 배지보다 양쪽 halo만큼 큰 실루엣을 destinationOut으로 → 아래 배터리를 도려내 투명 간격
                badgeImage(badge.symbol, side: badgeSide + basePointSize * haloRatio * 2, weight: badge.weight)
                    .foregroundStyle(.black)
                    .blendMode(.destinationOut)
                    .offset(x: badgeX)
                // 실제 배지(불투명). 정사각 bbox 중앙정렬(세로/비대칭 자동), 가로는 단자 보정.
                badgeImage(badge.symbol, side: badgeSide, weight: badge.weight)
                    .foregroundStyle(.black)
                    .offset(x: badgeX)
            }
        }
        .compositingGroup()   // destinationOut를 이 글리프 안으로 한정
    }

    private var badgeSide: CGFloat { basePointSize * badgeRatio }

    /// 배지 글리프(정사각 bbox에 scaledToFit → 세로/비대칭 자동 정렬, weight 보존). 색·blend는 호출부에서.
    private func badgeImage(_ name: String, side: CGFloat, weight: Font.Weight) -> some View {
        Image(systemName: name)
            .resizable()
            .fontWeight(weight)
            .scaledToFit()
            .frame(width: side, height: side)
            .symbolRenderingMode(.monochrome)
    }

    // MARK: 상태 → 배터리/배지 매핑
    private enum Symbols {
        static let charging     = "battery.100.bolt"   // 충전: 만충+번개 단일 글리프
        static let emptyBattery = "battery.0percent"   // 빈 배터리 베이스(유지/방전/과열/대기)
        static let pause        = "pause.fill"
        static let discharge    = "minus"
        static let heat         = "thermometer.high"
        static let unknown      = "questionmark"
    }

    private struct Badge { let symbol: String; let weight: Font.Weight }
    private struct Glyph { let base: String; let badge: Badge? }

    private var glyphSpec: Glyph {
        switch state {
        case .charging:        return Glyph(base: Symbols.charging,     badge: nil)
        case .discharging:     return Glyph(base: batteryLevelSymbol,   badge: nil)   // 분리방전 = %별 채움(배지 없음)
        case .limitReached:    return Glyph(base: Symbols.emptyBattery, badge: Badge(symbol: Symbols.pause,     weight: .semibold))
        case .forcedDischarge: return Glyph(base: Symbols.emptyBattery, badge: Badge(symbol: Symbols.discharge, weight: .black))
        case .heatPaused:      return Glyph(base: Symbols.emptyBattery, badge: Badge(symbol: Symbols.heat,      weight: .semibold))
        case .suspended:       return Glyph(base: Symbols.emptyBattery, badge: Badge(symbol: Symbols.unknown,   weight: .black))
        }
    }

    /// 분리방전 %를 SF Symbol 채움 단계(0/25/50/75/100)로.
    private var batteryLevelSymbol: String {
        switch percent ?? 0 {
        case 88...:   return "battery.100"
        case 63..<88: return "battery.75"
        case 38..<63: return "battery.50"
        case 13..<38: return "battery.25"
        default:      return "battery.0"
        }
    }
}
