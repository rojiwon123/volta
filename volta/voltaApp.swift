//
//  voltaApp.swift
//  volta
//

import SwiftUI

@main
struct voltaApp: App {
    // 메뉴바 아이템은 NSStatusItem(AppDelegate)에서 직접 관리한다.
    // MenuBarExtra는 라벨 크기를 바 두께로 클램프해 크기 제어가 불가능하므로 사용하지 않는다.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // 메뉴바 전용 앱(Dock 숨김: LSUIElement). 표시할 Window 씬은 없음.
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBar = MenuBarController(monitor: .shared)
    }
}
