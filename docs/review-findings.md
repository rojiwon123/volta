# 코드 리뷰 지적사항 & 조치 (2차 패스)

Swift 6 strict concurrency + 보안 관점의 리뷰(서브에이전트) 결과와 조치 내역입니다. 컴파일러가 없어 **수정 자체도 실기 빌드로 재확인 필요**합니다.

## 고친 것 (이번 커밋)

| 우선 | 지적 | 파일 | 조치 |
|------|------|------|------|
| P0 | 코드서명 요구사항에 `$(DEVELOPMENT_TEAM)` 리터럴 — 빌드 치환 안 됨 → 사실상 모든 연결 거부/무력화 | HelperListener / HelperConstants | 팀ID 상수화 + 요구사항 빌더, **미설정 시 fail-closed(연결 거부)** |
| P0 | 헬퍼가 앱이 보낸 `HelperPolicy`를 무검증 사용 | HelperService / HelperPolicy | `validated()` 클램프(범위/ NaN), setter에서 강제 적용 |
| P0 | 어댑터 차단(강제 방전)을 raw Bool로 무조건 수행 | HelperService | 정책상 강제 방전 활성일 때만 차단 허용(켜기는 항상 허용) |
| P1 | sleep 직전 충전차단을 비동기 Task로 실행 → IOAllowPowerChange가 먼저 돌아 적용 누락 | SleepWatcher / HelperService | `applyChargingForSleepBlocking`(세마포어+타임아웃)로 **동기 적용 후 sleep 승인** |
| P1 | XPC 오류 핸들러가 비어 있어 헬퍼 다운 시 `withCheckedContinuation`이 영구 hang | HelperClient | 오류 핸들러에서 resume + `ResumeOnce` 중복방지 + `interruptionHandler` |
| P1 | `applyCurrentPolicy`가 항상 previous=.suspended → 히스테리시스 불일치 | HelperService | 직전 상태 영속화(`_lastState`)로 앱과 동일 판단 |
| P1 | 강제 방전 해제 시 어댑터가 꺼진 채 방치(배터리 방전 지속) | HelperService / BatteryMonitor | 비활성 시 어댑터 복원 보장(reconcile) |
| P1 | 상태 변화 없을 때만 SMC 적용 → 외부 리셋 후 미복구 | BatteryMonitor | N틱마다 재적용 + 중복 쓰기 최소화(applied 상태 추적) |
| P2 | poll 루프가 매회 `self?.pollInterval` 접근 | BatteryMonitor | interval 1회 캡처 |
| — | 종료 시 충전 영구 제한 위험 | main.swift / HelperService | SIGTERM 핸들러 → `restoreSafeDefaults()` |

## 남긴 의심점 (실기에서 확인/추가 조치 필요)

1. **getDiagnostics 등 reply-after-invalidation**: 헬퍼가 `Task` 안에서 reply를 부르는데, 그 사이 XPC 연결이 무효화되면 reply 호출이 트랩될 수 있음. NSXPC 런타임 특성이라 코드만으로 완전 방지 어려움 → 연결 수명 관리/모니터링으로 확인 필요. (낮은 빈도)
2. **SMCKit ABI 미검증**: `SMCParamStruct` 레이아웃, selector(`handleYPCEvent=2`), cmd 코드(read=5/write=6/info=9), 결과코드(132=keyNotFound)는 통용 규약 기반 **가정**. 실기에서 IOKit 호출 성공/실패로 검증.
3. **SleepWatcher 정리 누락(경미)**: `IODeregisterForSystemPower`/notifier 해제 미구현. 장기 상주 데몬이라 영향 적으나 정리 코드 추가 권장.
4. **IORegistryEntryCreateCFProperties 캐스팅**: `as? Int`/`as? Bool`는 CFNumber/CFBoolean 브리징에 의존. 일부 키에서 실패 가능 → 실기에서 nil 여부 확인.
5. **반올림 규약 차이**: Swift `.rounded()`(0.5→away) vs Python(은행가) — `verification-results.md` 참고. 동작 영향 미미.
6. **App Sandbox 최종 결정**: 현재 off. on 상태에서 IOKit 읽기 가부를 실측 후 확정.
7. **무료 Personal Team의 SMAppService daemon 등록 가능 범위** 미확인.

## 리뷰가 "정상"으로 확인한 것

- VoltaCore 모델들의 `Sendable` 적합성, `SMCKit`을 actor 내부에 가둔 격리 설계.
- XPC는 `Data`/`String`/`Bool`만 오가므로 `NSXPCInterface.setClasses` 추가 설정 불필요(opaque Data+JSON 방식 적절).
- `didSet`가 init 중 발화하지 않아 부작용 없음.
- 비샌드박스 + Hardened Runtime 조합(이 부류 앱에 적절).
- App Intents/SMAppService/MenuBarExtra API 사용 형태는 타당.
