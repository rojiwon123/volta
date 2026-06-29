//
//  PowerFlowView.swift
//  volta
//
//  기능 6: 라이브 전력 흐름(AlDente식). 좌(소스)→우(sink), L→R. 0W 흐름은 PowerFlow가 안 담아 자동 숨김.
//   - 좌측 소스: 어댑터(bolt) / 방전 배터리.  우측 sink: 노트북 / 충전 배터리.  어댑터 아래엔 정격 와트.
//
//  형태(노드별 분리 셀 + 일정 두께 곡선 채널):
//   · 노드(아이콘) 하나당 셀 하나. 같은 쪽 노드 2개면 cellGap만큼 벌려 분리(엣지마다 소스 셀 → sink 셀).
//   · 셀 높이: 한쪽 2셀이면 반대쪽 단일(허브) 셀 = 그 두 셀 높이의 "합". 양쪽 단일이면 두 셀 높이 통일(max).
//   · 채널 두께 = 그 채널이 혼자 닿는 쪽 셀의 면 높이(uniform, 오목 없음). 접점들을 셀 중앙 touch-stack →
//     허브 셀은 Σ두께 = 셀높이라 꽉 차며 합류, 소스→sink는 S곡선으로 휜다. 셀-채널 사이엔 약간의 틈(channelGap).
//   · 셀·채널 모두 같은 불투명 회색(surface), 테두리 없음. 외부 그림자는 셀+채널 묶음의 통합 실루엣에 한 번(.compositingGroup).
//     셀의 채널 쪽 변은 각지게(flat), 바깥 모서리만 rounded. 채널 안엔 통일 색 파동만, 셀 안엔 아이콘만.
//

import AppKit
import SwiftUI
import VoltaCore

struct PowerFlowView: View {
    let flow: PowerFlow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("전력 흐름").font(.subheadline)
            diagram.frame(height: Metrics.height)
        }
    }

    private var diagram: some View {
        GeometryReader { geo in
            let g = layout(in: geo.size)
            ZStack {
                surfaceLayer(g)   // 셀+채널(통합 실루엣 외부 그림자 한 번)
                waveLayer(g)      // 채널 안 흐르는 파동
                labelLayer(g)     // 밴드별 W 라벨
                iconLayer(g)      // 셀 안 아이콘(+정격 라벨)
                if g.edges.isEmpty {   // 활성 흐름 0(거의 없음/데이터 없음) — 빈 상태
                    Text("전력 흐름 없음").font(.caption).foregroundStyle(.tertiary)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                }
            }
        }
    }

    // 셀·채널을 같은 surface로 채운 한 그룹 → 통합 실루엣에 외부 그림자 한 번(조각마다 X). 테두리 없음.
    private func surfaceLayer(_ g: Layout) -> some View {
        ZStack {
            ForEach(Array(g.cells.enumerated()), id: \.offset) { _, c in
                cellShape(c)
            }
            ForEach(g.edges) { e in
                BandShape(startX: g.startX, endX: g.endX, srcY: e.srcY, dstY: e.dstY, thick: e.thick)
                    .fill(Metrics.surface)
            }
        }
        .compositingGroup()
        .shadow(color: .black.opacity(0.28), radius: 3.5, x: 0, y: 1.5)
    }

    // 채널 path로 clip한 채 L→R로 흐르는 하이라이트 스트라이프(통일 색).
    private func waveLayer(_ g: Layout) -> some View {
        TimelineView(.animation) { tl in
            let phase = wavePhase(tl.date)
            Canvas { ctx, size in
                let span = max(g.endX - g.startX, 1)
                let stripe = span * 0.5
                let base = g.startX - 2 * stripe + phase * (2 * stripe)
                for e in g.edges {
                    let path = bandPath(g.startX, g.endX, e.srcY, e.dstY, e.thick)
                    ctx.drawLayer { layer in
                        layer.clip(to: path)
                        var x = base
                        while x < g.endX + stripe {
                            let r = CGRect(x: x, y: 0, width: stripe, height: size.height)
                            layer.fill(Path(r), with: .linearGradient(
                                Gradient(colors: [Metrics.channel.opacity(0), Metrics.channel.opacity(0.62), Metrics.channel.opacity(0)]),
                                startPoint: CGPoint(x: r.minX, y: size.height / 2),
                                endPoint: CGPoint(x: r.maxX, y: size.height / 2)))
                            x += 2 * stripe
                        }
                    }
                }
            }
        }
    }

    // 밴드 곡선 중심선 위(소스 쪽 u≈0.32)에 W 라벨.
    private func labelLayer(_ g: Layout) -> some View {
        ForEach(g.edges) { e in
            let u: CGFloat = 0.32
            let s = u * u * (3 - 2 * u)   // smoothstep: 곡선 중심선 따라가기
            Text(wattStr(e.watts)).font(.caption2).monospacedDigit().foregroundStyle(.primary)
                .position(x: g.startX + (g.endX - g.startX) * u, y: e.srcY + (e.dstY - e.srcY) * s)
        }
    }

    // 셀 안 아이콘. 좌측 어댑터면 아래에 정격 와트 라벨.
    private func iconLayer(_ g: Layout) -> some View {
        ZStack {
            ForEach(g.leftIcons, id: \.node) { ic in
                Image(systemName: ic.node == .adapter ? "bolt.fill" : "battery.100")
                    .font(.system(size: g.iconSize * 0.92)).foregroundStyle(.secondary)
                    .position(x: g.leftX, y: ic.y)
                if ic.node == .adapter, let rated = flow.adapterRatedWatts {
                    Text(wattStr(rated))
                        .font(.system(size: 8, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
                        .position(x: g.leftX, y: ic.y + g.iconSize / 2 + 6)
                }
            }
            ForEach(g.rightIcons, id: \.node) { ic in
                Image(systemName: ic.node == .laptop ? "laptopcomputer" : "battery.100.bolt")
                    .font(.system(size: g.iconSize)).foregroundStyle(.secondary)
                    .position(x: g.rightX, y: ic.y)
            }
        }
    }

    // 셀 면(surface 채움): 채널 쪽 변은 각지게(flat), 바깥쪽 모서리만 rounded.
    private func cellShape(_ c: CellBox) -> some View {
        UnevenRoundedRectangle(
            topLeadingRadius: c.roundedLeft ? Metrics.corner : 0,
            bottomLeadingRadius: c.roundedLeft ? Metrics.corner : 0,
            bottomTrailingRadius: c.roundedLeft ? 0 : Metrics.corner,
            topTrailingRadius: c.roundedLeft ? 0 : Metrics.corner,
            style: .continuous)
            .fill(Metrics.surface)
            .frame(width: c.rect.width, height: c.rect.height)
            .position(x: c.rect.midX, y: c.rect.midY)
    }

    // MARK: - 레이아웃 계산

    private func layout(in size: CGSize) -> Layout {
        let w = size.width, h = size.height
        let me = flow.edges
        let hasRated = flow.adapterRatedWatts != nil

        // 좌=소스 노드(어댑터/방전배터리), 우=sink 노드(노트북/충전배터리). 실제 등장하는 것만, 위→아래 순서.
        let leftNodes = order([.adapter, .battery], appearingIn: me.map(\.from))
        let rightNodes = order([.laptop, .battery], appearingIn: me.map(\.to))

        // 활성 흐름 0(예: "거의 없음" — 모든 전력이 임계값 이하)이면 엣지·노드가 비어 셀/접점 계산이 빈 배열을 인덱싱 → 크래시.
        // → 빈 레이아웃(셀·채널 없음)을 반환하고, diagram은 "전력 흐름 없음"만 표시.
        guard !leftNodes.isEmpty, !rightNodes.isEmpty else {
            return Layout(
                leftX: Metrics.cellW / 2, rightX: w - Metrics.cellW / 2,
                startX: Metrics.cellW + Metrics.channelGap, endX: w - Metrics.cellW - Metrics.channelGap,
                iconSize: Metrics.iconSize, cells: [], leftIcons: [], rightIcons: [], edges: [])
        }
        // 한 셀 안에서 여러 채널을 쌓을 때의 순서 키(교차 방지): 소스 쪽은 sink 순, sink 쪽은 소스 순.
        func srcRank(_ n: PowerFlow.Node) -> Int { n == .adapter ? 0 : 1 }
        func dstRank(_ n: PowerFlow.Node) -> Int { n == .laptop ? 0 : 1 }

        let heightOf = cellHeights(leftNodes, rightNodes, hasRated: hasRated)
        let (L, leftIconY) = placeSide(leftNodes, isLeft: true, in: size, heightOf: heightOf, hasRated: hasRated)
        let (R, rightIconY) = placeSide(rightNodes, isLeft: false, in: size, heightOf: heightOf, hasRated: hasRated)

        // 채널 두께 = 그 채널이 "혼자 닿는" 쪽 셀의 면 높이(반대쪽 허브에선 두께들이 stack되어 허브 면을 꽉 채움).
        func fromCnt(_ n: PowerFlow.Node) -> Int { me.reduce(0) { $0 + ($1.from == n ? 1 : 0) } }
        func thick(_ e: PowerFlow.Edge) -> CGFloat { fromCnt(e.from) == 1 ? heightOf[e.from]! : heightOf[e.to]! }

        // 각 셀에서 닿는 채널들을 두께만큼 셀 중앙에 touch-stack → 엣지별 접점 Y.
        func endpoints(_ nodes: [PowerFlow.Node], _ rects: [PowerFlow.Node: CGRect],
                       edgesAt: (PowerFlow.Node) -> [PowerFlow.Edge]) -> [String: CGFloat] {
            var out: [String: CGFloat] = [:]
            for n in nodes {
                let es = edgesAt(n)
                var y = rects[n]!.midY - es.reduce(0) { $0 + thick($1) } / 2
                for e in es { let t = thick(e); out[e.id] = y + t / 2; y += t }
            }
            return out
        }
        let srcY = endpoints(leftNodes, L) { n in me.filter { $0.from == n }.sorted { dstRank($0.to) < dstRank($1.to) } }
        let dstY = endpoints(rightNodes, R) { n in me.filter { $0.to == n }.sorted { srcRank($0.from) < srcRank($1.from) } }

        let edges = me.map { e in
            PortedEdge(id: e.id, srcY: srcY[e.id] ?? h / 2, dstY: dstY[e.id] ?? h / 2, thick: thick(e), watts: CGFloat(e.watts))
        }
        let cells = leftNodes.map { CellBox(rect: L[$0]!, roundedLeft: true) }
            + rightNodes.map { CellBox(rect: R[$0]!, roundedLeft: false) }
        return Layout(
            leftX: Metrics.cellW / 2, rightX: w - Metrics.cellW / 2,
            startX: Metrics.cellW + Metrics.channelGap, endX: w - Metrics.cellW - Metrics.channelGap,
            iconSize: Metrics.iconSize, cells: cells,
            leftIcons: leftNodes.map { IconPos(node: $0, y: leftIconY[$0]!) },
            rightIcons: rightNodes.map { IconPos(node: $0, y: rightIconY[$0]!) },
            edges: edges)
    }

    /// 노드별 셀 contact 면 높이.
    ///  · 한쪽 2셀 / 반대쪽 1셀 → 그 1셀(허브) = 반대편 두 셀 높이의 합(채널들이 허브 면을 꽉 채워 합류).
    ///  · 양쪽 모두 1셀 → 두 셀 높이를 max로 통일.
    private func cellHeights(_ leftNodes: [PowerFlow.Node], _ rightNodes: [PowerFlow.Node], hasRated: Bool) -> [PowerFlow.Node: CGFloat] {
        // 단일 셀 자연 높이: 아이콘 + 패딩, 어댑터는 정격 라벨만큼 더 큼.
        func natural(_ n: PowerFlow.Node, _ isLeft: Bool) -> CGFloat {
            (isLeft && n == .adapter && hasRated)
                ? Metrics.cellPad + Metrics.iconSize + Metrics.ratedGap + Metrics.ratedH + Metrics.cellPad
                : Metrics.iconSize + 2 * Metrics.cellPad
        }
        var out: [PowerFlow.Node: CGFloat] = [:]
        if leftNodes.count == 1 && rightNodes.count == 1 {
            let u = max(natural(leftNodes[0], true), natural(rightNodes[0], false))
            out[leftNodes[0]] = u; out[rightNodes[0]] = u
        } else if leftNodes.count >= 2 {
            for n in leftNodes { out[n] = natural(n, true) }
            out[rightNodes[0]] = leftNodes.reduce(0) { $0 + natural($1, true) }
        } else {
            for n in rightNodes { out[n] = natural(n, false) }
            out[leftNodes[0]] = rightNodes.reduce(0) { $0 + natural($1, false) }
        }
        return out
    }

    /// 한 변의 노드들을 위→아래로 cellGap 틈을 두고 쌓아 세로 중앙 정렬. 셀 rect + 아이콘 Y 반환.
    /// (어댑터+정격은 아이콘+라벨 블록을 셀 중앙 정렬.)
    private func placeSide(_ nodes: [PowerFlow.Node], isLeft: Bool, in size: CGSize,
                           heightOf: [PowerFlow.Node: CGFloat], hasRated: Bool)
        -> ([PowerFlow.Node: CGRect], [PowerFlow.Node: CGFloat]) {
        let hs = nodes.map { heightOf[$0]! }
        let total = hs.reduce(0, +) + Metrics.cellGap * CGFloat(max(nodes.count - 1, 0))
        let x: CGFloat = isLeft ? 0 : size.width - Metrics.cellW
        var y = (size.height - total) / 2
        var rects: [PowerFlow.Node: CGRect] = [:], iconY: [PowerFlow.Node: CGFloat] = [:]
        for (n, ch) in zip(nodes, hs) {
            let rect = CGRect(x: x, y: y, width: Metrics.cellW, height: ch)
            rects[n] = rect
            iconY[n] = (isLeft && n == .adapter && hasRated)
                ? rect.midY - (Metrics.iconSize + Metrics.ratedGap + Metrics.ratedH) / 2 + Metrics.iconSize / 2
                : rect.midY
            y += ch + Metrics.cellGap
        }
        return (rects, iconY)
    }

    // MARK: - 헬퍼

    private func order(_ pref: [PowerFlow.Node], appearingIn used: [PowerFlow.Node]) -> [PowerFlow.Node] {
        pref.filter { used.contains($0) }
    }
    private func wavePhase(_ date: Date) -> CGFloat {
        CGFloat(date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Metrics.wavePeriod) / Metrics.wavePeriod)
    }
    private func wattStr(_ w: Double) -> String {
        let r = (w * 10).rounded() / 10
        return r == r.rounded() ? "\(Int(r))W" : String(format: "%.1fW", r)
    }
}

// MARK: - 조정 노브(상수)

private enum Metrics {
    static let height: CGFloat = 90        // 다이어그램 세로 높이
    static let cellW: CGFloat = 34         // 셀 가로 너비
    static let cellGap: CGFloat = 16       // 같은 쪽 셀 사이 간격(넉넉히 분리)
    static let channelGap: CGFloat = 3     // 셀-채널 사이 틈
    static let cellPad: CGFloat = 7        // 셀 안 여백
    static let corner: CGFloat = 9         // 셀 바깥 모서리 반경
    static let iconSize: CGFloat = 15      // 셀 아이콘 크기
    static let ratedH: CGFloat = 8         // 어댑터 정격 라벨 높이
    static let ratedGap: CGFloat = 3       // 아이콘-정격 라벨 간격
    static let wavePeriod: Double = 1.7    // 파동 한 주기(초)

    /// 채널·파동 통일 색.
    static let channel = Color(red: 0.18, green: 0.72, blue: 0.60)
    /// 셀·채널 면 색(불투명, 동적: 다크=배경보다 밝은 회색 / 라이트=어두운 회색).
    static let surface = Color(nsColor: NSColor(name: nil) { ap in
        ap.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 0.27, alpha: 1.0)
            : NSColor(white: 0.90, alpha: 1.0)
    })
}

// MARK: - 모델/Shape

private struct PortedEdge: Identifiable { let id: String; let srcY, dstY, thick, watts: CGFloat }
private struct IconPos { let node: PowerFlow.Node; let y: CGFloat }
private struct CellBox { let rect: CGRect; let roundedLeft: Bool }
private struct Layout {
    let leftX, rightX, startX, endX, iconSize: CGFloat
    let cells: [CellBox]
    let leftIcons: [IconPos]; let rightIcons: [IconPos]; let edges: [PortedEdge]
}

/// 일정 두께(thick) 리본을 소스 접점(srcY)→sink 접점(dstY)로 S곡선(좌우 수평 제어점)으로 휘게 그린다.
/// 위·아래 모서리가 같은 곡선을 thick만큼 평행 이동한 형태 → 가운데 오목/taper 없음.
/// nonisolated — Shape.path 등 비격리 컨텍스트(파동 Canvas 포함)에서도 호출 가능하게.
private nonisolated func bandPath(_ startX: CGFloat, _ endX: CGFloat,
                                  _ srcY: CGFloat, _ dstY: CGFloat, _ thick: CGFloat) -> Path {
    let cx = (startX + endX) / 2, t = thick / 2
    var p = Path()
    p.move(to: CGPoint(x: startX, y: srcY - t))
    p.addCurve(to: CGPoint(x: endX, y: dstY - t), control1: CGPoint(x: cx, y: srcY - t), control2: CGPoint(x: cx, y: dstY - t))
    p.addLine(to: CGPoint(x: endX, y: dstY + t))
    p.addCurve(to: CGPoint(x: startX, y: srcY + t), control1: CGPoint(x: cx, y: dstY + t), control2: CGPoint(x: cx, y: srcY + t))
    p.closeSubpath()
    return p
}

private struct BandShape: Shape {
    let startX, endX, srcY, dstY, thick: CGFloat
    nonisolated func path(in rect: CGRect) -> Path { bandPath(startX, endX, srcY, dstY, thick) }
}
