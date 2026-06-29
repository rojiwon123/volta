# 서명 팀(Apple Developer Team) 전환 체크리스트

무료 Apple ID(개인 팀) → **유료 Apple Developer Program 팀**으로 전환할 때 바꿔야 하는 지점.

> **결론(요약): 이제 팀 전환은 `Signing.xcconfig` 한 줄만 바꾸면 된다.**
> 과거엔 "코드 상수 1곳 + pbxproj 10곳"을 같은 값으로 동시에 바꿔야 했으나, 두 차례 리팩터로 단일화됐다:
> - **빌드 서명**: `DEVELOPMENT_TEAM`을 **`Signing.xcconfig` 한 줄**로 중앙화(프로젝트 base config → 전 타깃 상속). pbxproj의 흩어진 10곳 제거됨.
> - **런타임 XPC 팀 검증**: `HelperConstants`가 **자기 코드서명에서 팀을 런타임 파생**(SecCode)하므로 **손대지 않는다**(서명 팀과 자동 일치).
> - **SMAppService/데몬 plist**: 팀 ID를 하드코딩하지 않는다(`AssociatedBundleIdentifiers` = 번들 ID 기반). **손대지 않는다**.
>
> → **팀 전환 시 만져야 하는 곳 = 정확히 1곳 (`Signing.xcconfig`).** 실제 신규 값은 유료 계정 발급 후 확정(현재 계정 없음).

---

## 1. 전환 절차 (요약)

```bash
# 1) 유료 팀의 TeamIdentifier(= 서명 리프 인증서 subject.OU) 확인
security find-identity -v -p codesigning
#    또는 이미 서명된 산출물에서:
codesign -dv --verbose=4 DerivedData/Build/Products/Debug/volta.app 2>&1 | grep TeamIdentifier

# 2) Signing.xcconfig 한 줄 교체
#    DEVELOPMENT_TEAM = <DEVELOPMENT_TEAM>   →   DEVELOPMENT_TEAM = <신규_TEAM_ID>

# 3) 빌드 후 서명 팀 확인
codesign -dv --verbose=4 DerivedData/Build/Products/Debug/volta.app 2>&1 | grep TeamIdentifier
```

끝. **A-1(코드 상수)·XPC 요구 문자열은 손대지 않는다** — 런타임에 자기 서명에서 파생되어 자동 일치한다.

> ⚠️ **혼동 주의:** 무료 **Apple Development** 인증서의 **CN**에 박히는 개인 식별자(예 `CJ576XA3C2`)는
> **OU가 아니다**. 넣을 값은 항상 **TeamIdentifier(= 리프 인증서 `subject.OU`)**.

---

## 2. 왜 한 줄이면 되나 (메커니즘)

| 구성요소 | 팀 ID 출처 | 전환 시 |
|---|---|---|
| **빌드 서명** (앱/헬퍼/테스트) | `Signing.xcconfig`의 `DEVELOPMENT_TEAM` (프로젝트 레벨 base config로 전 타깃 상속) | **이 한 줄만 교체** |
| **런타임 XPC 검증** (`HelperConstants` → `HelperListener`) | 헬퍼가 `SecCode`로 **자기 TeamIdentifier 런타임 파생** → `anchor apple generic + 번들 ID 핀 + leaf[subject.OU]=<자기팀>` 요구 생성 | **자동** (앱·헬퍼가 같은 xcconfig로 서명 → 같은 팀 → 검증 통과) |
| **SMAppService/데몬 plist** | 팀 ID 미포함(`AssociatedBundleIdentifiers`=번들 ID) | **변경 없음** |

- **fail-closed**: 자기 팀을 못 읽으면(ad-hoc/팀없는 빌드) 요구가 nil → 모든 XPC 연결 거부. 빈 OU 요구로 무서명 연결을 통과시키지 않는다.
- 코드: `HelperConstants.makeClientRequirement(team:)`(순수, 테스트됨) + `currentTeamIdentifier()`(런타임 파생) + `HelperListener.shouldAcceptNewConnection`.
- ⚠️ 실제 SecCode peer 검증은 **서명된 빌드의 런타임에서만** 동작한다 — 효과 검증은 유료 팀 계정으로 헬퍼(SMAppService) 설치 후 가능(현재 키 매핑/단위 테스트까지만).

---

## 3. 배포 단계에서 함께 검토 (전환 자체로 깨지진 않음)

### 3-1. 서명 방식 `CODE_SIGN_STYLE = Automatic`
자기 맥 개발/사용은 **Automatic 유지로 충분**. **다른 맥 배포(Developer ID + notarization)** 단계에서만 "Developer ID Application" 아이덴티티/별도 distribution 구성 검토.

### 3-2. 하드닝 런타임 / 엔타이틀먼트
- `ENABLE_HARDENED_RUNTIME = YES` ✅ 이미 켜짐(notarization 전제). 팀 전환과 무관.
- `volta/volta.entitlements`(app-sandbox=false), `voltaHelper/voltaHelper.entitlements`(빈 키): 팀 ID 없음. 변경 불필요.

### 3-3. 번들 식별자 `com.rojiwon.*`
문자열 자체는 변경 불필요. 유료 팀에서는 이 App ID(번들 prefix)를 개발자 포털 팀에 등록(Automatic 서명이 자동 처리). 다른 reverse-domain을 원할 때만 변경이며, 그 경우 `HelperConstants`·`Info.plist`·데몬 plist(`Label`/`MachServices`/`AssociatedBundleIdentifiers`)가 서로 일치해야 함.

---

## 4. 변경 불필요(감사 결과 깨끗)

- **`Signing.xcconfig` 외 pbxproj에 `DEVELOPMENT_TEAM` 없음**: 10곳 제거 후 base config 상속으로 단일화됨.
- **`HelperConstants`에 하드코딩 팀 없음**: `developmentTeamID` 상수 제거됨(런타임 파생).
- **`build.sh`**: 하드코딩 서명 값 없음(pbxproj/xcconfig에 위임).
- **`CODE_SIGN_IDENTITY` / `PROVISIONING_PROFILE*`**: 명시 설정 없음(Automatic).
- **앱→헬퍼 방향 검증 부재**: 앱(`HelperClient`)은 헬퍼 연결에 `setCodeSigningRequirement`를 걸지 않음(헬퍼 신뢰는 SMAppService 등록 + 앱 번들 동봉 경로). 즉 **팀 검증 코드 지점은 헬퍼 단방향 1곳**이고, 그마저 런타임 파생이라 팀 전환 시 손댈 코드가 없다.

---

## 부록: 리팩터 이력 (과거 분산 구조 → 단일화)

| 시점 | 빌드 서명 팀 | 런타임 검증 팀 |
|---|---|---|
| 과거 | pbxproj `DEVELOPMENT_TEAM` **10곳** | `HelperConstants.developmentTeamID` **하드코딩 1곳** (둘을 같은 값으로 수동 동기화 필요) |
| **현재** | `Signing.xcconfig` **1줄** (전 타깃 상속) | **자기 서명에서 런타임 파생** (수동 동기화 불필요) |

→ 전환 시 누락 위험(옛날엔 11곳)이 **1곳(xcconfig)**으로 줄었다.
