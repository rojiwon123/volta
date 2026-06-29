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
import OSLog
import SwiftUI
import VoltaCore

@MainActor
final class MenuBarController: NSObject {

    private let monitor: BatteryMonitor
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()

    /// 팝오버 고정 크기. **콘텐츠 높이가 바뀌어도 팝오버는 리사이즈하지 않는다** — 이로써 "표시 레이아웃
    /// 패스 도중 팝오버 리사이즈"라는 `_NSDetectedLayoutRecursion`의 근본 원인을 제거한다. 콘텐츠는
    /// ContentView 안에서 ScrollView로 감싸 이 높이를 넘으면 스크롤된다(외형/폭 보존).
    static let popoverWidth: CGFloat = 280
    /// 풀 컨트롤(모든 기능 표시) 상태에 맞춘 고정 높이. 평소엔 스크롤 없이 다 보이고, 예외적으로 더 길면
    /// (강제방전 게이지·점검 결과 등) 스크롤. (측정 근거: 풀 상태 콘텐츠 fittingHeight≈651[DEBUG, 프리뷰 포함].)
    #if DEBUG
    static let popoverHeight: CGFloat = 660   // DEBUG: 프리뷰 섹션 포함 풀 상태.
    #else
    static let popoverHeight: CGFloat = 600   // Release: 프리뷰 없는 풀 상태.
    #endif

    init(monitor: BatteryMonitor) {
        self.monitor = monitor
        super.init()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)

        // 호스팅 컨트롤러의 자동 preferredContentSize 구동을 끈다(sizingOptions=[]) → SwiftUI intrinsic
        // 높이 변화가 팝오버 크기로 전파되지 않는다. 팝오버 크기는 우리가 고정 제어한다(아래 contentSize).
        let hosting = NSHostingController(rootView: ContentView(monitor: monitor))
        hosting.sizingOptions = []
        popover.behavior = .transient
        popover.contentViewController = hosting
        popover.contentSize = NSSize(width: Self.popoverWidth, height: Self.popoverHeight)

        monitor.start()
        observe()   // 최초 렌더 + 변화 구독

        #if DEBUG
        // [검증 훅] 레이아웃 재귀 재현용 — env VOLTA_AUTOOPEN_POPOVER=1이면 런치 직후 팝오버를 자동으로
        // 연 뒤 **콘텐츠 높이 변화를 반복 유발**(컨트롤/조건부 행 토글)해 표시 중 리사이즈 경로를 stress한다.
        // 통합 로그(subsystem=com.rojiwon.volta, category=harness)로 측정 높이/진행을 남긴다. 평소엔 비활성.
        // env 또는 플래그 파일(/tmp/volta-harness)로 트리거 — `open`(LaunchServices) 실행 시 env가 전달되지
        // 않아도 파일 플래그로 켤 수 있게 한다.
        if ProcessInfo.processInfo.environment["VOLTA_AUTOOPEN_POPOVER"] == "1"
            || FileManager.default.fileExists(atPath: "/tmp/volta-harness") {
            runLayoutHarness()
        }
        #endif
    }

    #if DEBUG
    private let harnessLog = Logger(subsystem: "com.rojiwon.volta", category: "harness")
    private var harnessCycle = 0
    private var harnessTimer: Timer?
    private func runLayoutHarness() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            self.togglePopover()
            // 풀 상태 콘텐츠 높이 측정(고정 높이 결정 근거) — 같은 monitor로 별도 호스팅에 sizeThatFits.
            let probe = NSHostingController(rootView: ContentView(monitor: self.monitor))
            probe.view.layoutSubtreeIfNeeded()
            let fit = probe.sizeThatFits(in: NSSize(width: 280, height: 5000))
            let line = "fittingHeight=\(Int(fit.height.rounded())) isControlSupported=\(self.monitor.isControlSupported) popoverShown=\(self.popover.isShown)\n"
            self.harnessLog.notice("\(line, privacy: .public)")
            // 통합 로그가 이 환경에서 안 잡히므로 파일로도 남긴다(고정 높이 결정 근거 회수용).
            try? line.write(toFile: "/tmp/volta-harness-out", atomically: true, encoding: .utf8)
            // 콘텐츠 높이 변화를 반복 유발 → 표시 중 리사이즈/재귀 stress. (heat 토글=온도행/슬라이더,
            // preview 토글=프리뷰 행. 짝수 회 토글이라 끝나면 원상복귀.)
            self.harnessCycle = 0
            self.harnessTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.monitor.heatProtectionEnabled.toggle()
                    self.monitor.previewEnabled.toggle()
                    self.harnessCycle += 1
                    // 루프 모드(/tmp/volta-harness-loop): lldb가 백트레이스를 잡을 시간을 벌도록 stress를
                    // 무한 반복한다(팝오버가 닫혀 있으면 다시 열고 토글 지속). status item 렌더도 매번 갱신.
                    let loop = FileManager.default.fileExists(atPath: "/tmp/volta-harness-loop")
                    if self.harnessCycle % 12 == 0 {
                        let cs = self.popover.contentSize
                        let done = "stress cycles=\(self.harnessCycle) popoverShown=\(self.popover.isShown) contentSize=\(Int(cs.width))x\(Int(cs.height)) loop=\(loop)\n"
                        self.harnessLog.notice("\(done, privacy: .public)")
                        if let h = FileHandle(forWritingAtPath: "/tmp/volta-harness-out") {
                            h.seekToEndOfFile(); h.write(Data(done.utf8)); try? h.close()
                        }
                        if loop {
                            if !self.popover.isShown { self.togglePopover() }   // 닫혔으면 다시 열어 표시 레이아웃 유발.
                        } else {
                            self.harnessTimer?.invalidate()
                        }
                    }
                }
            }
        }
    }
    #endif

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
