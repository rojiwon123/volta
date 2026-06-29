//
//  HelperConstants.swift
//  VoltaCore
//
//  앱·헬퍼가 공유하는 식별자. SMAppService 등록과 XPC 연결에 사용.
//
//  ⚠️ 보안: XPC peer(클라이언트=앱) 검증용 코드서명 요구 문자열은 **팀 ID를 하드코딩하지 않고**
//     런타임에 "자기(헬퍼) 코드서명에서 팀 식별자를 파생"해 만든다(아래 currentTeamIdentifier).
//     팀을 바꿔도(Signing.xcconfig 한 줄) 별도 수정 없이 자동 일치한다.
//

import Foundation
#if canImport(Security)
import Security
#endif

public enum HelperConstants {
    /// 헬퍼 데몬 실행 파일/번들 식별자.
    public static let helperBundleID = "com.rojiwon.volta.helper"

    /// LaunchDaemon Label = plist 파일명(.plist 제외)과 일치해야 한다.
    public static let daemonPlistName = "com.rojiwon.volta.helper"

    /// XPC Mach 서비스 이름(헬퍼 plist의 MachServices 키와 일치해야 한다).
    public static let machServiceName = "com.rojiwon.volta.helper.xpc"

    /// 메인 앱 번들 식별자(헬퍼가 연결 클라이언트를 코드서명으로 검증할 때 핀으로 사용).
    public static let appBundleID = "com.rojiwon.volta"

    /// 클라이언트(앱) 검증용 코드서명 요구 문자열을 만든다. **순수 함수 — 단위 테스트 대상.**
    /// 조건(셋 다): Apple anchor(`anchor apple generic`) + 기대 번들 ID 핀 + 팀(leaf `subject.OU`) 일치.
    /// - fail-closed: `team`이 nil/빈 문자열이면 **nil**을 반환한다 — 빈 OU 요구(`subject.OU = ""`)로
    ///   무서명/팀없는 연결을 통과시키지 않는다. 호출측(HelperListener)은 nil이면 모든 연결을 거부.
    public static func makeClientRequirement(team: String?) -> String? {
        guard let team, !team.isEmpty else { return nil }
        return "anchor apple generic and identifier \"\(appBundleID)\" "
            + "and certificate leaf[subject.OU] = \"\(team)\""
    }

    /// 런타임에 **자기(이 프로세스=헬퍼) 코드서명**에서 읽은 팀 식별자. 못 읽으면 nil(fail-closed).
    /// 팀 없는 ad-hoc/개발 빌드(서명에 TeamIdentifier 없음)에서는 nil → 헬퍼 제어가 비활성된다.
    public static func currentTeamIdentifier() -> String? {
        CodeSigningIdentity.selfTeamIdentifier()
    }

    /// 자기 팀을 런타임 파생해 만든 클라이언트 검증 요구 문자열. 자기 팀을 못 읽으면 nil(fail-closed).
    /// (상대 팀을 못 읽는 경우는 시스템이 `leaf[subject.OU]` 요구 불일치로 연결을 거부한다.)
    public static var clientCodeSigningRequirement: String? {
        makeClientRequirement(team: currentTeamIdentifier())
    }
}

// MARK: - 자기 코드서명에서 팀 식별자 파생

/// 자기 프로세스의 코드서명 정보에서 TeamIdentifier를 읽는다.
/// ⚠️ 실제 SecCode 검증은 **서명된 빌드의 런타임에서만** 의미가 있다. swift test(ad-hoc)에서는
///    팀이 없어 nil이 정상이다 — 그래서 단위 테스트는 순수 `makeClientRequirement(team:)`만 검증한다.
enum CodeSigningIdentity {
    #if canImport(Security)
    static func selfTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }
    #else
    static func selfTeamIdentifier() -> String? { nil }
    #endif
}
