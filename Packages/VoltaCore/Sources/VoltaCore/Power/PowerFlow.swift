//
//  PowerFlow.swift
//  VoltaCore
//
//  raw 전력 메트릭(PowerMetrics) + AC 연결 여부를 "소스(좌) → sink(우)" 엣지 그래프로 변환.
//  - 항상 L→R: 좌측 노드(어댑터/방전 배터리)에서 우측 노드(노트북/충전 배터리)로 흐른다.
//  - 충전 시 배터리는 "우측 sink"(어댑터가 노트북+배터리 둘로 갈라짐). 방전 시 배터리는 "좌측 소스".
//  - 활성(임계값 초과) 엣지만 담는다 → 0W 흐름은 자동 숨김(동적).
//  - 배터리 부호 규약(충전 +/방전 −)은 ⚠️ 미검증 "가정"이라 batteryPositiveMeansCharging 한 곳에서 관리.
//

import Foundation

public struct PowerFlow: Sendable, Equatable {

    public enum Node: Sendable, Equatable, Hashable {
        case adapter     // 좌: 어댑터
        case battery     // 방전=좌 소스 / 충전=우 sink
        case laptop      // 우: 노트북
    }

    /// 전력 흐름이 나타내는 지배적 상태. 메뉴바 아이콘이 흐름과 "동일 기준"으로 그리도록
    /// 같은 분류를 공유한다(측정된 배터리 전력 부호 + AC 연결만으로 결정).
    public enum Activity: String, Sendable, Equatable {
        case charging      // AC → 배터리 (충전)
        case discharging   // 배터리 → 노트북 (방전, 원인 무관)
        case holding       // AC 연결 + 배터리 입출력 ~0 (유지/bypass)
        case idle          // AC 없음 + 배터리 ~0 (거의 없음)
    }

    public struct Edge: Sendable, Equatable, Identifiable {
        public let from: Node     // 좌측
        public let to: Node       // 우측
        public let watts: Double
        public var id: String { "\(from)->\(to)" }
        public init(from: Node, to: Node, watts: Double) {
            self.from = from; self.to = to; self.watts = watts
        }
    }

    /// 활성 엣지(임계값 초과만). 비어 있으면 "흐름 없음".
    public let edges: [Edge]
    /// 노트북 총 소비(W). 참고/표시용.
    public let systemWatts: Double?
    /// 연결된 어댑터 정격 와트(W) — 어댑터 아이콘 아래 표시용. 미연결이면 nil.
    public let adapterRatedWatts: Double?
    /// 지배적 상태(충전/방전/유지/유휴). 메뉴바 아이콘이 이 값으로 흐름과 일치하게 그린다.
    public let activity: Activity

    public init(edges: [Edge], systemWatts: Double?, adapterRatedWatts: Double? = nil, activity: Activity = .idle) {
        self.edges = edges; self.systemWatts = systemWatts; self.adapterRatedWatts = adapterRatedWatts
        self.activity = activity
    }

    // MARK: 튜닝값
    /// ⚠️ 배터리 전력 부호 규약(미검증 가정). true면 "양수 = 충전(배터리로 유입)".
    ///    실기에서 반대면 false로 — 이 한 줄로 충전/방전 방향이 전체 반전된다.
    public static let batteryPositiveMeansCharging = true
    /// 흐름으로 간주할 최소 전력(W). 노이즈로 인한 깜빡임 방지.
    public static let activeThresholdWatts = 0.5

    public static func from(power: PowerMetrics, isACPresent: Bool) -> PowerFlow {
        let eps = activeThresholdWatts
        let system = power.systemWatts
        let adapter = isACPresent ? power.adapterWatts : nil

        // 배터리 부호 → 충전/방전 분류
        var charging = false, chargeW = 0.0, dischargeW = 0.0
        if let b = power.batteryWatts, abs(b) > eps {
            let isCharge = batteryPositiveMeansCharging ? (b > 0) : (b < 0)
            if isCharge { charging = true; chargeW = abs(b) } else { dischargeW = abs(b) }
        }

        var edges: [Edge] = []
        // 어댑터 → 노트북: 충전 중이면 노트북 몫=systemWatts(없으면 어댑터−충전), 아니면 어댑터 전부.
        if let a = adapter, a > eps {
            let laptopW = charging ? (system ?? max(a - chargeW, 0)) : a
            if laptopW > eps { edges.append(Edge(from: .adapter, to: .laptop, watts: laptopW)) }
        }
        // 충전: 어댑터 → 배터리(우측 sink). (충전은 AC 전제)
        if charging, chargeW > eps, isACPresent {
            edges.append(Edge(from: .adapter, to: .battery, watts: chargeW))
        }
        // 방전: 배터리(좌측 소스) → 노트북
        if dischargeW > eps {
            edges.append(Edge(from: .battery, to: .laptop, watts: dischargeW))
        }
        // 지배적 상태(흐름과 동일 기준): 방전 우선 → 충전 → AC 유지 → 유휴.
        let activity: Activity
        if dischargeW > eps { activity = .discharging }
        else if charging, chargeW > eps { activity = .charging }
        else if isACPresent { activity = .holding }
        else { activity = .idle }

        // 어댑터 정격: AC 연결 시에만(어댑터 아이콘 아래 표시).
        let rated = isACPresent ? power.adapterRatedWatts : nil
        return PowerFlow(edges: edges, systemWatts: system, adapterRatedWatts: rated, activity: activity)
    }
}
