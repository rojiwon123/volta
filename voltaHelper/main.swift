//
//  main.swift
//  voltaHelper (root LaunchDaemon, Command Line Tool)
//
//  SMAppService.daemon 으로 등록되어 root로 상주한다. 역할:
//   - XPC 서버로 앱의 명령(충전/어댑터/정책)을 받아 SMC 특권 쓰기 수행.
//   - sleep/wake 알림을 직접 수신해 사전 푸시된 정책을 즉시 적용(기능 8).
//   - 상한 도달까지 sleep 억제(IOPMAssertion, 기능 2).
//
//  ⚠️ 헬퍼 타깃은 VoltaCore 패키지에 링크되어야 한다.
//

import Foundation
import VoltaCore

FileHandle.standardError.write(Data("[voltaHelper] starting…\n".utf8))

let delegate = HelperListenerDelegate()
let listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
listener.delegate = delegate
listener.resume()

// sleep/wake 감시 시작(기능 8 / 기능 2).
SleepWatcher.shared.start()

// 안전장치: 종료 시그널을 받으면 충전 정상화 후 종료(배터리 영구 제한 방지).
signal(SIGTERM, SIG_IGN)
let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termSource.setEventHandler {
    Task {
        await HelperService.shared.restoreSafeDefaults()
        exit(0)
    }
}
termSource.resume()

// LaunchDaemon: run loop 유지.
RunLoop.main.run()
