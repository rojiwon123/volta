//
//  DeviceInfo.swift
//  VoltaCore
//
//  기기 탐지(capability gating 입력). 아키텍처 / 모델 식별자 / macOS 버전을 읽는다.
//  순수 데이터 구조 + Darwin sysctl 조회. 1차 분기 기준은 "아키텍처 + 모델"이다.
//  (SMC/펌웨어 버전은 "참고 지문"으로만 둔다 — 쉽게 못 읽으면 nil.)
//

import Foundation

/// 한 기기의 탐지 결과 스냅샷.
public struct DeviceInfo: Sendable, Equatable {
    /// 머신 아키텍처(`hw.machine`). 예: "arm64" / "x86_64".
    public let architecture: String
    /// Apple Silicon 머신인지(`hw.optional.arm64 == 1`). Intel이면 false.
    public let isAppleSilicon: Bool
    /// 모델 식별자(`hw.model`). 예: "Mac17,5".
    public let modelIdentifier: String
    /// macOS 버전 문자열. 예: "26.5.1".
    public let osVersion: String
    /// 참고용 펌웨어/SMC 지문(있으면). 1차 분기 기준 아님 — 진단/기록용. 현재는 nil 가능.
    public let smcFingerprint: String?

    public init(
        architecture: String,
        isAppleSilicon: Bool,
        modelIdentifier: String,
        osVersion: String,
        smcFingerprint: String? = nil
    ) {
        self.architecture = architecture
        self.isAppleSilicon = isAppleSilicon
        self.modelIdentifier = modelIdentifier
        self.osVersion = osVersion
        self.smcFingerprint = smcFingerprint
    }

    /// 데이터 없음(비-Darwin/탐지 실패) 기본값.
    public static let unknown = DeviceInfo(
        architecture: "unknown", isAppleSilicon: false, modelIdentifier: "unknown", osVersion: "unknown"
    )

    /// 현재 실행 중인 이 기기의 탐지 결과.
    public static var current: DeviceInfo {
        #if canImport(Darwin)
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let os = "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        return DeviceInfo(
            architecture: Sysctl.string("hw.machine") ?? "unknown",
            isAppleSilicon: (Sysctl.int("hw.optional.arm64") ?? 0) == 1,
            modelIdentifier: Sysctl.string("hw.model") ?? "unknown",
            osVersion: os,
            smcFingerprint: nil   // 참고 지문: SMC 버전 키 read-back은 팀 계정 후 헬퍼 경로에서 채울 자리.
        )
        #else
        return .unknown
        #endif
    }
}

#if canImport(Darwin)
import Darwin

/// sysctl 조회 헬퍼.
enum Sysctl {
    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }
    static func int(_ name: String) -> Int? {
        var value = 0
        var size = MemoryLayout<Int>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }
}
#endif
