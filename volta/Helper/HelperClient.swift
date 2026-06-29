//
//  HelperClient.swift
//  volta (app)
//
//  헬퍼 데몬 등록(SMAppService) + XPC 클라이언트.
//  앱은 비특권으로 SMC를 "읽기"만 하고, "쓰기"는 전부 이 클라이언트를 통해 헬퍼에 위임한다.
//
//  ⚠️ 앱 타깃은 VoltaCore 패키지에 링크되어야 한다(Xcode 연결 — docs 참조).
//

import Foundation
import ServiceManagement
import VoltaCore

@MainActor
@Observable
final class HelperClient {

    enum Status: Equatable {
        case notRegistered
        case requiresApproval
        case enabled
        case failed(String)
    }

    private(set) var status: Status = .notRegistered
    /// **실제 제어 가능 여부**: SMAppService 등록 status(.enabled)는 "등록 의도"만 보고 데몬이 실제로
    /// 로드/연결됐는지는 보장하지 않는다(미로드여도 .enabled로 뜰 수 있음). 그래서 실제 XPC 왕복
    /// (getVersion 핑) 성공 여부를 신뢰 신호로 둔다. isControlSupported는 이 값을 본다.
    private(set) var isReachable: Bool = false
    private var connection: NSXPCConnection?

    private var service: SMAppService {
        SMAppService.daemon(plistName: HelperConstants.daemonPlistName + ".plist")
    }

    // MARK: 등록/해제 (기능 1 전제)

    func registerIfNeeded() {
        do {
            try service.register()
            refreshStatus()
        } catch {
            status = .failed("등록 실패: \(error.localizedDescription)")
        }
    }

    func unregister() {
        try? service.unregister()
        refreshStatus()
    }

    func refreshStatus() {
        switch service.status {
        case .enabled:            status = .enabled
        case .requiresApproval:   status = .requiresApproval
        case .notRegistered:      status = .notRegistered
        case .notFound:           status = .notRegistered
        @unknown default:         status = .notRegistered
        }
    }

    /// 사용자에게 승인 UI(시스템 설정 > 로그인 항목)를 띄운다.
    func openSystemSettingsForApproval() {
        SMAppService.openSystemSettingsLoginItems()
    }

    // MARK: XPC

    private func ensureConnection() -> NSXPCConnection {
        if let c = connection { return c }
        let c = NSXPCConnection(machServiceName: HelperConstants.machServiceName,
                                options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: VoltaHelperProtocol.self)
        // NSXPC가 백그라운드 큐에서 호출하므로 @Sendable(비격리)로 둬야 한다.
        // (Default MainActor 격리 환경에서 일반 클로저는 MainActor에 묶여 격리 위반으로 크래시)
        c.invalidationHandler = { @Sendable [weak self] in
            Task { @MainActor in self?.connection = nil }
        }
        // interrupted(일시 단절)도 캐시를 비워 다음 호출에서 재연결.
        c.interruptionHandler = { @Sendable [weak self] in
            Task { @MainActor in self?.connection = nil }
        }
        c.resume()
        connection = c
        return c
    }

    /// 공통 호출 래퍼. 오류 핸들러에서 반드시 continuation을 resume해 "행"을 방지한다.
    /// reply/오류가 중복 호출돼도 한 번만 resume(ResumeOnce).
    private func call(
        _ body: @escaping @Sendable (VoltaHelperProtocol, @escaping @Sendable (Bool) -> Void) -> Void
    ) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let once = ResumeOnce(cont)
            let conn = ensureConnection()
            let proxy = conn.remoteObjectProxyWithErrorHandler { @Sendable _ in
                once.fire(false)
            } as? VoltaHelperProtocol
            guard let proxy else { once.fire(false); return }
            body(proxy) { ok in once.fire(ok) }
        }
    }

    // MARK: 명령 (async 래핑)

    func setChargingAllowed(_ allowed: Bool) async -> Bool {
        await call { proxy, done in proxy.setChargingAllowed(allowed) { ok, _ in done(ok) } }
    }

    func setAdapterEnabled(_ enabled: Bool) async -> Bool {
        await call { proxy, done in proxy.setAdapterEnabled(enabled) { ok, _ in done(ok) } }
    }

    /// 정책 사전 푸시(기능 8).
    func pushPolicy(_ policy: HelperPolicy) async -> Bool {
        guard let data = try? policy.encoded() else { return false }
        return await call { proxy, done in proxy.applyPolicy(data) { ok, _ in done(ok) } }
    }

    func setSleepInhibit(_ enabled: Bool) async -> Bool {
        await call { proxy, done in proxy.setSleepInhibit(enabled) { ok, _ in done(ok) } }
    }

    /// 헬퍼 생존 핑(실제 XPC 왕복). getVersion 응답이 오면 연결됨(true), 연결 실패/미로드면 false.
    /// 결과를 isReachable에 반영 — 등록 status와 무관하게 "실제로 제어 가능한지"를 판정한다.
    @discardableResult
    func ping() async -> Bool {
        let ok = await call { proxy, done in proxy.getVersion { _ in done(true) } }
        isReachable = ok
        return ok
    }
}

/// continuation을 정확히 한 번만 resume하기 위한 thread-safe 가드.
/// continuation(비-Sendable)을 클래스가 직접 보관해, @Sendable 클로저가 continuation을
/// 직접 캡처하는 것(Swift 6 위반)을 피한다.
private nonisolated final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<Bool, Never>?
    init(_ cont: CheckedContinuation<Bool, Never>) { self.cont = cont }
    func fire(_ value: Bool) {
        lock.lock()
        let c = cont
        cont = nil
        lock.unlock()
        c?.resume(returning: value)
    }
}
