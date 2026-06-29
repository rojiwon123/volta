# 하드웨어 실기 검증 가이드

코드로 못 끝내고 **사용자가 실기에서** 확인해야 하는 항목들의 단계별 가이드.
미검증 가정(SMC 키·배터리 부호·CHTE/CHIE 매직값·온도 단위)과 root 헬퍼 셋업을 순서대로 검증한다.

> 참고 문서: [`remaining-work.md`](remaining-work.md) · [`user-test-checklist.md`](user-test-checklist.md) ·
> [`Xcode-환경설정-가이드.md`](Xcode-환경설정-가이드.md) · 루트 [`../CLAUDE.md`](../CLAUDE.md)

**핵심**: **Phase 1까지는 안전**(읽기만, root 불필요). **Phase 3(SMC 쓰기)** 는 Phase 2(헬퍼) 선행 +
배터리 안전 절차를 보수적으로. 막히면 즉시 복구(아래).

---

## Phase 0 — 빌드·실행 (무료 Apple ID)

- Xcode에서 **무료 Apple ID**로 자동 **Apple Development** 서명(개인 팀) 설정 → **⌘R**.
- 메뉴바에 글리프, 클릭 시 팝오버(충전 범위 RangeSlider / 과열 임계 / 강제 방전 / 전력 흐름)가 뜨면 OK.
- 헬퍼 미설치 상태라 **읽기·UI만 동작**(SMC 쓰기는 Phase 2 이후).

## Phase 1 — 읽기 검증 (안전, root 불필요)

**① 전력 부호 방향**
- "전력 프리뷰" 끄고 실측 상태에서, **충전 중 / 방전 중** 전력 흐름 방향을 본다.
  - 충전 중인데 화살표가 배터리→노트북(방전)으로 보이거나 그 반대면 부호가 뒤집힌 것.
- 틀리면 `PowerFlow.batteryPositiveMeansCharging`(현재 `true`) **한 줄만 뒤집어** 재확인.
- (이 맥은 SMC 전력키가 nil → IOKit `Amperage` 기반 폴백을 쓰며, Amperage는 +충전 규약이라 보통 맞음.)

**② 실제 와트 대조**
- 터미널: `sudo powermetrics --samplers smc -i1 -n1` (또는 `... --samplers battery`) 로
  어댑터/배터리/시스템 와트를 읽어 팝오버 전력 흐름의 W와 대조.
- 이 맥은 **SMC 전력키(PDTR/PPBR/PSTR)가 nil → IOKit 폴백**(`Amperage×Voltage`, `AdapterDetails.Current×AdapterVoltage`)로
  산출. 값이 powermetrics와 크게 어긋나면 폴백 공식/단위(mA·mV) 점검.
- 빠른 단독 확인: `ioreg -r -c AppleSmartBattery` 의 `Amperage`/`Voltage`/`AdapterDetails`.

**③ 온도 단위 대조**
- 과열 보호 ON → **임계 온도 슬라이더(30~60℃)**. 헤더에 표시되는 현재 온도(℃)가 실제 체감/다른 도구와 맞는지 확인.
- `AppleSmartBattery.Temperature`가 0.01K인지 0.1℃인지 모델차 가능 → 표시 온도가 비현실적이면
  `SMARTBattery.read()`의 온도 변환식 점검.

## Phase 2 — 헬퍼 셋업 (root 등록)

1. **헬퍼 타깃**: `voltaHelper`(Command Line Tool) 타깃 빌드 + **LaunchDaemon plist**(`com.rojiwon.volta.helper.plist`)
   연결. plist의 `Label`/`MachServices`가 `HelperConstants.daemonPlistName`(`com.rojiwon.volta.helper`)·
   `machServiceName`(`com.rojiwon.volta.helper.xpc`)와 일치해야 함. (상세: [`Xcode-환경설정-가이드.md`](Xcode-환경설정-가이드.md))
2. **팀 ID**: `HelperConstants.developmentTeamID`(현재 `"CJ576XA3C2"`)를 **본인 서명 팀 ID**로. 앱·헬퍼 **서명 팀 일치**,
   헬퍼를 앱 번들 `Contents/Library/...`에 CopyFiles로 포함.
3. **등록·승인**: 앱 실행 시 `SMAppService`로 헬퍼 등록(`registerIfNeeded()`) → **시스템 설정 → 일반 →
   로그인 항목 → 백그라운드에서 허용** 에서 승인.
4. **연결 확인**: 팝오버 헬퍼 상태가 "연결됨"이고, XPC 호출 시 **code 4099(연결 끊김/서명 불일치)가 안 뜨면 정상**.
   4099면 서명 팀/요건(`developmentTeamID`) 불일치 가능 → 2번 재확인.

## Phase 3 — SMC 쓰기 검증 ⚠️ 배터리 안전

> **먼저 복구법부터 숙지**(쓰기가 잘못 걸려도 되돌릴 수 있게):
> - 헬퍼 부트아웃 후 재등록, 또는 **재부팅**(대부분 SMC 충전 상태 원복). Apple Silicon은 SMC 리셋이 재부팅에 포함.
> - 강제 방전/충전 억제가 남아 있으면 충전기 분리·재연결 + 재부팅. 체크리스트: [`user-test-checklist.md`](user-test-checklist.md).
> - 보수적으로: 한 번에 하나씩, 충전량 충분할 때, 결과 확인 후 다음 단계.

**① 충전 제한(CHTE)**
- 충전 범위 상한을 **현재 %보다 낮게** 설정 + 충전기 연결 → 충전이 **멈추는지** 확인.
- 확인: `pmset -g batt` (Not charging 표시) / `ioreg -r -c AppleSmartBattery | grep IsCharging`.
- 안 멈추면 **CHTE 키/매직 바이트값**이 이 모델(Tahoe 26)에서 다를 수 있음 → battery SMC 소스/AlDente류 키와 대조.

**② 강제 방전(CHIE)**
- 강제 방전 ON(목표% 슬라이더) + 충전기 연결 → 어댑터 차단되어 **방전되는지** 확인.
- 한계: **클램셸(덮개 닫힘)** 에서 어댑터를 끊으면 즉시 잠들 수 있어 강제 방전 미지원(팝오버 경고 표시).

**③ 조용히 실패하면**
- 쓰기는 성공처럼 보이는데 동작이 없으면 **FourCC 키/매직값**(CHTE/CHIE, battery 소스)이 **Tahoe 26 경로와 일치하는지** 확인.
- 키 코드·바이트값을 한 곳(`SMCKey`/SMC 쓰기 호출부)에서 관리하므로, 검증된 값으로 교체.

---

검증 완료 후, 위 가정들이 확정되면 `../CLAUDE.md`의 "⚠️ 미검증" 항목에서 해당 줄을 "검증됨"으로 갱신할 것.
