//
//  SMCFloat.swift
//  VoltaCore
//
//  SMC 데이터 타입 디코딩(순수 함수, 플랫폼 비의존 → 단위 테스트 가능).
//
//  - flt  : 4바이트 little-endian IEEE-754 single precision. (PDTR/PPBR/PSTR 등 전력값)
//  - ioft : 8바이트 부호 없는 고정소수점. 상위/하위 분할 규약은 모델별로 다를 수 있어 검증 필요.
//  - sp78 : 2바이트 부호 있는 8.8 고정소수점(일부 온도 키).
//
//  ⚠️ 어떤 키가 어떤 타입을 쓰는지(dataType)는 SMC가 키마다 보고한다.
//     여기서는 바이트 → 값 변환만 담당하고, "키-타입 매핑"은 실기에서 확인한다.
//

import Foundation

public enum SMCFloat {

    /// flt: 4바이트 LE IEEE-754 float.
    public static func decodeFLT(_ bytes: [UInt8]) -> Double? {
        guard bytes.count == 4 else { return nil }
        let bits = UInt32(bytes[0])
            | (UInt32(bytes[1]) << 8)
            | (UInt32(bytes[2]) << 16)
            | (UInt32(bytes[3]) << 24)
        return Double(Float(bitPattern: bits))
    }

    /// sp78: 2바이트 부호 있는 8.8 고정소수점.
    public static func decodeSP78(_ bytes: [UInt8]) -> Double? {
        guard bytes.count == 2 else { return nil }
        let raw = Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        return Double(raw) / 256.0
    }

    /// ioft: 8바이트 부호 없는 고정소수점. 기본 규약은 "정수부 6.2바이트"가 아니라
    ///       전체를 64bit 정수로 보고 2^(소수비트) 로 나누는 형태가 흔하다.
    ///       소수 비트수(fractionBits)는 키에 따라 다르므로 인자로 받는다.
    ///       (대표적으로 ioft 온도/전류 키에서 사용. 정확한 비트수는 검증 필요.)
    public static func decodeIOFT(_ bytes: [UInt8], fractionBits: Int) -> Double? {
        guard bytes.count == 8, fractionBits >= 0, fractionBits < 64 else { return nil }
        var raw: UInt64 = 0
        // SMC는 big-endian 으로 ioft를 보고하는 경우가 많음(검증 필요).
        for b in bytes { raw = (raw << 8) | UInt64(b) }
        return Double(raw) / Double(UInt64(1) << fractionBits)
    }

    /// 단일 바이트 정수(예: 충전 비율 BatteryChargeKey).
    public static func decodeUInt8(_ bytes: [UInt8]) -> Int? {
        guard bytes.count == 1 else { return nil }
        return Int(bytes[0])
    }
}
