//
//  VoltaHelperProtocol.swift
//  VoltaCore
//
//  앱(클라이언트) ↔ root 헬퍼(서버) 간 XPC 계약. NSXPCConnection 용 @objc 프로토콜.
//  완료 핸들러 기반(반환형이 있는 동기 메서드는 XPC에서 지원되지 않음).
//
//  ⚠️ NSXPCConnection 코드서명 검증(같은 팀/요구사항)은 양쪽 구현에서 설정 필요.
//

import Foundation

@objc public protocol VoltaHelperProtocol {

    /// 헬퍼 생존/버전 확인.
    func getVersion(reply: @escaping @Sendable (String) -> Void)

    /// 충전 허용/중단(기능 1·5). 성공 여부와 오류 메시지를 반환.
    func setChargingAllowed(_ allowed: Bool,
                            reply: @escaping @Sendable (Bool, String?) -> Void)

    /// 어댑터 급전 on/off(기능 3, 강제 방전). 클램셸 등으로 불가 시 success=false.
    func setAdapterEnabled(_ enabled: Bool,
                           reply: @escaping @Sendable (Bool, String?) -> Void)

    /// 정책값 사전 푸시(기능 8). 헬퍼는 이 값을 보관했다가 sleep/wake 시 즉시 적용.
    /// data = HelperPolicy의 JSON 인코딩.
    func applyPolicy(_ data: Data,
                     reply: @escaping @Sendable (Bool, String?) -> Void)

    /// 상한 도달까지 sleep 억제(기능 2) 활성/해제. 헬퍼가 IOPMAssertion을 관리.
    func setSleepInhibit(_ enabled: Bool,
                         reply: @escaping @Sendable (Bool, String?) -> Void)

    /// 현재 헬퍼가 보고하는 키 가용성/상태(진단용).
    func getDiagnostics(reply: @escaping @Sendable (Data?) -> Void)
}
