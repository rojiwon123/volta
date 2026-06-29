# 검증 결과 (2차 패스)

이 환경에는 Swift 툴체인이 없어 **Swift 컴파일/실행은 불가**합니다. 순수 로직은 Python으로 동일 알고리즘을 재구현해 교차검증했습니다. **하드웨어/SMC/XPC/컴파일은 여전히 실기 검증 대상**입니다.

## 1. Python 교차검증: 35/35 통과

검증한 항목(`ChargePolicyEngine`, `HelperPolicy.validated`, `ChargeAction`, `effectiveChargePercent`, `SMCFloat`):

- **flt 디코딩**: 5.0(`00 00 A0 40`), −12.5, 0.0, 1.0 — IEEE754 LE 일치.
- **sp78 디코딩**: 1.5(`01 80`), −1.0(`FF 00`), 30.0 — 부호 8.8 고정소수점 일치.
- **상태머신**: 충전/상한/히스테리시스(78 유지, 74 재개, 75 정확경계 재개)/방전/과열(충전중만)/과열무시(미연결)/강제방전 우선/목표도달 중지/무데이터.
- **하드웨어 우선 비율**: hw 있으면 반올림 사용, 없으면 OS, 둘 다 없으면 nil.
- **ChargeAction 매핑**: 6개 상태 전부.
- **정책 클램프(보안)**: limit 50~100, start < limit 강제, dischargeTarget 10~95, ceiling 30~60 + NaN→nil.

## 2. Swift 단위 테스트 (작성됨, 실기 `swift test` 필요)

`Packages/VoltaCore/Tests/VoltaCoreTests/PolicyAndDecodeTests.swift` 에 위 항목을 Swift Testing(`@Test`)으로 작성. 실기에서 `cd Packages/VoltaCore && swift test` 로 실행해 통과 확인 필요.

## 3. 알려진 미세 차이 / 주의

- **반올림 규약**: Swift `Double.rounded()`는 0.5에서 "0에서 먼 쪽"으로 반올림(82.5→83). Python `round()`는 은행가 반올림(82.5→82). 하드웨어 비율이 정확히 `x.5%`일 때만 1 차이. 동작 영향 미미하나, 정밀이 필요하면 Swift 쪽 규약을 기준으로 본다.
- **전력 합산 검산**: 부호 규약이 미확정이라 "adapter = battery + system" 같은 관계는 **가정**일 뿐입니다. 실기에서 충전/방전 각각의 부호와 합산 관계를 측정해 `PowerMetrics`/`SMCFloat` 주석의 가정을 확정해야 합니다.

## 4. 재현 방법

`/tmp/verify2.py`(이 세션 한정)에 35개 단언이 있습니다. 동일 로직을 실기 `swift test`가 대체합니다. 핵심은 **Swift 단위 테스트가 진짜 검증의 기준**이고, Python은 알고리즘 정합성의 사전 확인입니다.
