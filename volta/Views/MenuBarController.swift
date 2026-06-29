//
//  MenuBarController.swift
//  volta
//
//  메뉴바 아이템을 NSStatusItem으로 직접 관리한다.
//
//  왜 MenuBarExtra가 아니라 NSStatusItem인가:
//   - MenuBarExtra는 label 뷰를 메뉴바 두께(~22pt)에 맞춰 정규화/클램프한다.
//     그래서 .frame(width:height:)·font(size:)의 '절대값'이 시각적으로 먹지 않는다.
//   - NSStatusItem은 우리가 만든 NSImage를 그대로 표시하므로 너비/폰트/내부
//     레이아웃을 실제 픽셀로 제어할 수 있다. (단, 높이는 여전히 바 두께가 상한 —
//     이는 OS 한계로 어떤 방식으로도 넘을 수 없다.)
//
//  디자인 재사용: 아이콘 모양/색/% 레이아웃은 SwiftUI MenuBarLabel 한 곳에 두고,
//  ImageRenderer로 래스터화해 상태아이템 버튼 이미지로 넣는다. → 크기 노브
//  (MenuBarLabel.batterySizeRatio/percentFontRatio/badgeRatio)가 실제로 반영된다.
//
//  렌더 모드: isTemplate = true 로 단색 템플릿 처리 → 메뉴바 라이트/다크에 자동
//  적응(네이티브 룩, 가시성 보장). 상태별 '색' 구분은 팝오버 헤더에서 유지된다.
//  (메뉴바에서도 색을 쓰고 싶으면 render()의 isTemplate = false 로 바꾸면 된다.
//   단 .primary 등이 외형에 자동 적응하지 않으니 색을 고정값으로 정해야 함.)
//

import AppKit
import SwiftUI
import VoltaCore

@MainActor
final class MenuBarController: NSObject {

    private let monitor: BatteryMonitor
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()

    init(monitor: BatteryMonitor) {
        self.monitor = monitor
        super.init()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)

        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: ContentView(monitor: monitor)
        )

        monitor.start()
        observe()   // 최초 렌더 + 변화 구독

        #if DEBUG
        // [임시 검증 훅] 레이아웃 재귀 재현용 — env VOLTA_AUTOOPEN_POPOVER=1이면 런치 직후 실제
        // 상태아이템 팝오버를 자동으로 연다(메뉴바 클릭 우회). 평소엔 비활성.
        if ProcessInfo.processInfo.environment["VOLTA_AUTOOPEN_POPOVER"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.togglePopover()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    print("[volta-harness] popover.isShown=\(self?.popover.isShown ?? false) "
                        + "button=\(self?.statusItem.button != nil)")
                }
            }
        }
        #endif
    }

    /// @Observable 상태 변화를 추적해 아이콘을 다시 그린다.
    private func observe() {
        withObservationTracking {
            // 프리뷰 인식 값을 읽음 → 프리뷰 ON/OFF·강제값 변화도 추적된다(DEBUG 한정).
            _ = monitor.menuBarState
            _ = monitor.menuBarPercent
        } onChange: {
            Task { @MainActor in
                self.render()
                self.observe()   // withObservationTracking은 1회성 → 재구독
            }
        }
        render()
    }

    /// MenuBarLabel(SwiftUI)을 NSImage로 래스터화해 버튼에 설정.
    private func render() {
        let renderer = ImageRenderer(content:
            MenuBarLabel(state: monitor.menuBarState, percent: monitor.menuBarPercent)
        )
        renderer.scale = statusItem.button?.window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor ?? 2

        guard let cg = renderer.cgImage else { return }
        // 이미지 높이를 메뉴바 두께에 "정확히" 맞춘다(너비는 종횡비 유지). MenuBarLabel이 캔버스를
        // barHeight로 고정해 그리므로 거의 일치하지만, 래스터 반올림으로 1~2px 초과하면 status item이
        // 또 축소(클램프)해 batterySizeRatio가 화면에 덜 먹힌다 → 높이를 thickness로 못박아 1:1 표시.
        let thickness = NSStatusBar.system.thickness
        let aspect = CGFloat(cg.width) / CGFloat(cg.height)
        let size = NSSize(width: thickness * aspect, height: thickness)
        let image = NSImage(cgImage: cg, size: size)
        image.isTemplate = true          // 메뉴바 외형 자동 적응(단색)
        statusItem.button?.image = image
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            // LSUIElement(accessory) 앱은 평소 비활성 상태다. 활성화 없이 .transient 팝오버를
            // show하면 최신 macOS에서 즉시 닫히거나 아예 표시되지 않는다(팝오버 안 뜸의 원인).
            // 먼저 앱을 활성화한 뒤 띄우고 key로 만들어 안정적으로 표시한다.
            NSApp.activate(ignoringOtherApps: true)
            // 메뉴바 아이콘 ↔ 팝오버 세로 간격. positioning rect를 버튼 bounds에서 아래로 offset해
            // (.minY 모서리 기준 → 팝오버가 그만큼 더 내려옴) 메뉴바와의 틈을 넓힌다.
            // ※ MenuBarLabel의 크기 노브 3개와는 무관한 별개 값. 키우면 더 벌어진다. 시각 보고 조정.
            let popoverGap: CGFloat = 0   // pt
            let anchor = button.bounds.offsetBy(dx: 0, dy: -popoverGap)
            popover.show(relativeTo: anchor, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            // ⚠️ 팝오버 열릴 때 monitor 상태를 갱신하지 않는다 — appear/표시 레이아웃 패스 중에 콘텐츠
            //    높이가 바뀌면(특히 컨트롤↔"기능 비활성화" 조건부 전환) NSHostingController가 표시 도중
            //    팝오버를 리사이즈해 AppKit 레이아웃 재귀 경고가 난다. 모든 콘텐츠 변이는 폴링 tick(타이머,
            //    레이아웃 패스 밖)으로만 일어나게 둔다. 표시 데이터는 10초 폴링으로 신선하게 유지됨.
        }
    }
}
