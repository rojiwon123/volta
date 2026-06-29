//
//  HelperListener.swift
//  voltaHelper
//
//  NSXPCListener 델리게이트. 들어오는 연결을 코드서명 요구사항으로 검증한 뒤
//  VoltaHelperProtocol을 노출한다.
//
//  ⚠️ 코드서명 검증 문자열은 런타임에 자기 서명에서 파생한 팀(HelperConstants)으로 만든다.
//     자기 팀을 못 읽으면(ad-hoc/팀없는 개발 빌드) fail-closed로 모든 연결 거부.
//

import Foundation
import VoltaCore

final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {

        // 보안: 연결한 클라이언트가 우리 앱(같은 팀)인지 코드서명으로 검증.
        // 자기 서명에서 팀을 못 읽으면(ad-hoc/팀없는 빌드) fail-closed(모든 연결 거부) — root 데몬을 무방비 노출하지 않는다.
        guard let requirement = HelperConstants.clientCodeSigningRequirement else {
            FileHandle.standardError.write(Data(
                "[voltaHelper] 자기 팀 식별자 파생 실패 → 연결 거부(fail-closed)\n".utf8))
            return false
        }
        // setCodeSigningRequirement(_:)는 macOS 13+ 제공. 위반 연결은 시스템이 자동 거부.
        newConnection.setCodeSigningRequirement(requirement)

        newConnection.exportedInterface = NSXPCInterface(with: VoltaHelperProtocol.self)
        newConnection.exportedObject = HelperService.shared
        newConnection.resume()
        return true
    }
}
