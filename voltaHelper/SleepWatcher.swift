//
//  SleepWatcher.swift
//  voltaHelper
//
//  기능 8: 헬퍼가 sleep/wake를 "직접" 수신해, 앱이 사전 푸시한 정책을 즉시 적용한다.
//  기능 2: 상한 도달 전까지 시스템 sleep을 억제(IOPMAssertion)한다.
//
//  IORegisterForSystemPower 콜백은 C 함수 포인터라 전역 함수로 두고 싱글턴에 위임한다.
//  ⚠️ 컴파일/동작 검증 불가(환경 제약). 실기 빌드 필요.
//

import Foundation
import IOKit
import IOKit.pwr_mgt

final class SleepWatcher: @unchecked Sendable {

    static let shared = SleepWatcher()

    private var rootPort: io_connect_t = 0
    private var notifierObject: io_object_t = 0
    private var notifyPortRef: IONotificationPortRef?
    private var sleepAssertionID: IOPMAssertionID = 0
    private var inhibitEnabled = false

    private init() {}

    // MARK: 시작

    func start() {
        notifyPortRef = nil
        rootPort = IORegisterForSystemPower(
            nil,                       // refcon (전역 싱글턴 사용)
            &notifyPortRef,
            systemPowerCallback,       // C 콜백
            &notifierObject
        )
        guard rootPort != 0, let port = notifyPortRef else {
            FileHandle.standardError.write(Data("[voltaHelper] IORegisterForSystemPower 실패\n".utf8))
            return
        }
        CFRunLoopAddSource(
            CFRunLoopGetCurrent(),
            IONotificationPortGetRunLoopSource(port).takeUnretainedValue(),
            .commonModes
        )
    }

    // MARK: sleep/wake 처리 (콜백에서 호출)

    func handleWillSleep(messageArgument: UnsafeMutableRawPointer?) {
        // sleep 직전에 충전 중단을 "동기"로 적용(기능 8).
        // Task로 비동기 적용하면 IOAllowPowerChange가 먼저 실행돼 적용 전에 잠들어 버린다.
        // 짧은 타임아웃으로 블록해 sleep 전환을 무한정 막지는 않는다.
        HelperService.shared.applyChargingForSleepBlocking()
        // 반드시 sleep 승인(지연 후엔 강제 sleep됨).
        IOAllowPowerChange(rootPort, Int(bitPattern: messageArgument))
    }

    func handleDidWake() {
        // 깨어나면 정책을 다시 적용.
        Task { await HelperService.shared.applyCurrentPolicy() }
    }

    func handleWillNotSleep(messageArgument: UnsafeMutableRawPointer?) {
        // idle sleep 취소 통지 등.
        IOAllowPowerChange(rootPort, Int(bitPattern: messageArgument))
    }

    // MARK: sleep 억제 (기능 2)

    func setSleepInhibit(_ enabled: Bool) {
        guard enabled != inhibitEnabled else { return }
        if enabled {
            var id: IOPMAssertionID = 0
            let reason = "volta: 충전 상한 도달까지 sleep 억제" as CFString
            let r = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason,
                &id
            )
            if r == kIOReturnSuccess {
                sleepAssertionID = id
                inhibitEnabled = true
            }
        } else {
            if sleepAssertionID != 0 {
                IOPMAssertionRelease(sleepAssertionID)
                sleepAssertionID = 0
            }
            inhibitEnabled = false
        }
    }
}

// MARK: - C 콜백 (전역)

// IOKit의 sleep/wake 메시지 상수는 함수형 매크로(iokit_common_msg)로 정의돼 있어
// Swift로 자동 임포트되지 않는다. 잘 알려진 고정값으로 직접 정의한다.
//   iokit_common_msg(x) = (sys_iokit | sub_iokit_common | x) = 0xE0000000 | x
private enum PMMessage {
    static let canSystemSleep: UInt32    = 0xE000_0270  // kIOMessageCanSystemSleep
    static let systemWillSleep: UInt32   = 0xE000_0280  // kIOMessageSystemWillSleep
    static let systemHasPoweredOn: UInt32 = 0xE000_0300 // kIOMessageSystemHasPoweredOn
}

private func systemPowerCallback(refcon: UnsafeMutableRawPointer?,
                                 service: io_service_t,
                                 messageType: UInt32,
                                 messageArgument: UnsafeMutableRawPointer?) {
    switch messageType {
    case PMMessage.systemWillSleep:
        SleepWatcher.shared.handleWillSleep(messageArgument: messageArgument)
    case PMMessage.canSystemSleep:
        SleepWatcher.shared.handleWillNotSleep(messageArgument: messageArgument)
    case PMMessage.systemHasPoweredOn:
        SleepWatcher.shared.handleDidWake()
    default:
        break
    }
}
