//
//  SMCKit.swift
//  VoltaCore
//
//  AppleSMC IOKit user-client 저수준 래퍼. 읽기는 비특권, 쓰기는 root 권한 필요.
//  플랫폼 의존이라 #if canImport(IOKit) 로 가드 — Linux 등에서는 컴파일 제외.
//
//  ⚠️ 컴파일/동작 검증 불가(이 작업 환경엔 Xcode/SDK 없음). 실기 빌드에서 확인 필요.
//  구조는 널리 쓰이는 SMC user-client 규약(SMCParamStruct, kSMCReadKey/kSMCWriteKey)을 따른다.
//

#if canImport(IOKit)
import Foundation
import IOKit

public enum SMCError: Error, Sendable {
    case serviceNotFound
    case openFailed(kern_return_t)
    case callFailed(kern_return_t)
    case keyNotFound(String)
    case unexpectedSize(expected: Int, got: Int)
    case notPrivileged
}

/// SMC와 통신하는 저수준 클라이언트. 단일 IO connection을 보유한다.
/// 동시 접근 직렬화는 상위 actor(SMCService)가 책임진다 — 이 타입은 non-Sendable.
public final class SMCKit {

    // MARK: SMC 통신 구조체 (커널 ABI와 일치해야 함)

    private struct SMCVersion {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
    }

    private struct SMCLimitData {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }

    private struct SMCKeyInfoData {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    // 32바이트 데이터 버퍼.
    private struct SMCBytes {
        var b: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
            (0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,
             0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0)
    }

    private struct SMCParamStruct {
        var key: UInt32 = 0
        var version = SMCVersion()
        var pLimitData = SMCLimitData()
        var keyInfo = SMCKeyInfoData()
        var padding: UInt16 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes = SMCBytes()
    }

    // selector 인덱스(AppleSMC user-client). 검증 필요.
    private enum Selector: UInt32 {
        case handleYPCEvent = 2
    }
    private enum SMCCmd: UInt8 {
        case readBytes = 5
        case writeBytes = 6
        case readKeyInfo = 9
    }

    private var connection: io_connect_t = 0

    public init() {}

    // MARK: 연결 수명주기

    public func open() throws {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSMC")
        )
        guard service != 0 else { throw SMCError.serviceNotFound }
        defer { IOObjectRelease(service) }

        let kr = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard kr == kIOReturnSuccess else { throw SMCError.openFailed(kr) }
    }

    public func close() {
        if connection != 0 {
            IOServiceClose(connection)
            connection = 0
        }
    }

    // MARK: 키 메타정보

    private func readKeyInfo(_ key: SMCKey) throws -> SMCKeyInfoData {
        var input = SMCParamStruct()
        input.key = key.fourCharCode
        input.data8 = SMCCmd.readKeyInfo.rawValue
        let output = try call(input)
        return output.keyInfo
    }

    /// 키 존재 여부 — **메타정보(readKeyInfo)만** 조회하므로 읽기 권한과 무관하다.
    /// 값 읽기(read) 기반 probe는 write-only 제어 키(CHTE/CHIE 등)에서 false-negative가 날 수 있어
    /// 키 존재 판별에는 이 메서드를 쓴다. (실제 키 존재/효과는 서명된 root 헬퍼 실기에서만 확정.)
    public func keyExists(_ key: SMCKey) -> Bool {
        guard let info = try? readKeyInfo(key) else { return false }
        return info.dataSize > 0
    }

    // MARK: 읽기

    /// 키의 원시 바이트를 읽는다(dataSize 만큼).
    public func read(_ key: SMCKey) throws -> [UInt8] {
        let info = try readKeyInfo(key)
        let size = Int(info.dataSize)
        guard size > 0 else { throw SMCError.keyNotFound(key.code) }

        var input = SMCParamStruct()
        input.key = key.fourCharCode
        input.keyInfo = info
        input.data8 = SMCCmd.readBytes.rawValue

        let output = try call(input)
        return Self.copyBytes(output.bytes, count: min(size, 32))
    }

    // MARK: 쓰기 (root 필요)

    /// 키에 바이트를 쓴다. 권한 부족 시 실패 — root 헬퍼에서만 성공해야 정상.
    public func write(_ key: SMCKey, bytes: [UInt8]) throws {
        let info = try readKeyInfo(key)

        var input = SMCParamStruct()
        input.key = key.fourCharCode
        input.keyInfo = info
        input.data8 = SMCCmd.writeBytes.rawValue
        Self.fillBytes(&input.bytes, from: bytes)

        _ = try call(input)
    }

    // MARK: 저수준 호출

    private func call(_ inputStruct: SMCParamStruct) throws -> SMCParamStruct {
        guard connection != 0 else { throw SMCError.openFailed(kIOReturnNotOpen) }
        var input = inputStruct
        var output = SMCParamStruct()
        var outSize = MemoryLayout<SMCParamStruct>.stride

        let kr = IOConnectCallStructMethod(
            connection,
            Selector.handleYPCEvent.rawValue,
            &input,
            MemoryLayout<SMCParamStruct>.stride,
            &output,
            &outSize
        )
        guard kr == kIOReturnSuccess else { throw SMCError.callFailed(kr) }
        if output.result == 132 { throw SMCError.keyNotFound("") } // kSMCKeyNotFound
        if output.result != 0 { throw SMCError.callFailed(kIOReturnError) }
        return output
    }

    // MARK: 튜플 ↔ 배열 유틸

    private static func copyBytes(_ t: SMCBytes, count: Int) -> [UInt8] {
        withUnsafeBytes(of: t) { raw in
            Array(raw.prefix(count)).map { $0 }
        }
    }

    private static func fillBytes(_ t: inout SMCBytes, from src: [UInt8]) {
        withUnsafeMutableBytes(of: &t) { raw in
            for i in 0..<min(src.count, 32) { raw[i] = src[i] }
        }
    }
}
#endif
