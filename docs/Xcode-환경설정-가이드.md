# volta — Xcode 환경 설정 가이드 (전체 아키텍처)

목표: macOS Tahoe 26 + Apple Silicon 전용, Swift 6, SwiftUI `MenuBarExtra`(Dock 숨김), 앱 + root 헬퍼 데몬 + 공유 Swift Package, `SMAppService`+XPC, App Intents.

> 이 문서는 Xcode UI 조작 안내입니다. **빌드 설정(2번)은 이미 pbxproj에 적용**되어 있고, **타깃 연결(4·5번)은 사용자가 Xcode에서 수행**해야 합니다(코드/plist/entitlements는 갖춰둠). 버전별로 명칭이 다를 수 있는 항목은 **(확인 필요)**.

## 1. 빌드 설정 — 적용 완료 (참고용)

프로젝트 아이콘 > Build Settings 에서 확인 가능. 이미 반영됨:

- Swift Compiler - Language > **Swift Language Version = 6**
- Swift Compiler - Concurrency > **Strict Concurrency Checking = Complete** (+ Approachable Concurrency=Yes, Default Actor Isolation=MainActor 기본 유지)
- Deployment > **macOS Deployment Target = 26.0**
- Architectures > **arm64**
- 앱: Info.plist Values > **Application is agent (UIElement) = Yes** (`LSUIElement`)
- 앱: Signing & Capabilities 에서 **App Sandbox 제거됨**(entitlements로 false), Hardened Runtime 유지
- 앱: `CODE_SIGN_ENTITLEMENTS = volta/volta.entitlements`

## 2. 메뉴바 앱 — 적용 완료

`voltaApp.swift`가 `MenuBarExtra { ContentView } label: { Image }` 로 전환됨. SwiftData 잔재 없음.

## 3. 공유 패키지 연결 — 사용자 작업 필요

`Packages/VoltaCore` 가 로컬 Swift Package로 존재. Xcode에서:

1. File > Add Package Dependencies… > **Add Local…** > `Packages/VoltaCore`.
2. 앱 타깃 General > Frameworks, Libraries, and Embedded Content 에 **VoltaCore** 추가.
3. (헬퍼 타깃 생성 후) 헬퍼에도 VoltaCore 링크.

> 권장: 프레임워크 타깃 대신 **로컬 Swift Package**(이미 이 방식). CLI 헬퍼 연동·테스트가 깔끔.

## 4. 헬퍼 데몬 타깃 — 사용자 작업 필요

`voltaHelper/` 에 소스·plist·entitlements·Info.plist가 준비됨. Xcode에서:

1. File > New > Target > macOS > **Command Line Tool**, 이름 `voltaHelper`.
2. 자동 생성 `main.swift` 제거 후, `voltaHelper/`의 파일들을 이 타깃 멤버로 추가.
3. Build Settings:
   - `PRODUCT_BUNDLE_IDENTIFIER = com.rojiwon.volta.helper`
   - `INFOPLIST_FILE = voltaHelper/Info.plist`, `CREATE_INFOPLIST_SECTION_IN_BINARY = YES` **(확인 필요 — 키 명칭)**
   - `CODE_SIGN_ENTITLEMENTS = voltaHelper/voltaHelper.entitlements`
4. 헬퍼는 **App Sandbox capability 추가하지 않음**(off).
5. 헬퍼 plist를 앱 번들에 동봉: 앱 타깃 Build Phases > New Copy Files Phase > Destination **Wrapper**, Subpath `Contents/Library/LaunchDaemons`, `com.rojiwon.volta.helper.plist` 추가. **(확인 필요 — Copy Files Destination)**
6. 헬퍼 실행 파일이 앱 번들 `Contents/MacOS/voltaHelper` 에 위치하도록 구성(plist BundleProgram 경로와 일치).

## 5. 서명 / Capabilities

- 앱·헬퍼 동일 Team, Automatically manage signing.
- 무료 Personal Team으로 시작 가능하나 **SMAppService daemon 등록 가능 범위는 (확인 필요)** — 안 되면 유료 계정/Developer ID.
- `HelperListener.swift`의 코드서명 요구사항 문자열 `$(DEVELOPMENT_TEAM)` → 실제 팀 ID로 치환.
- 배포: Developer ID 서명 + notarization.

## 6. App Intents

별도 빌드 단계 불필요(메타데이터 자동 추출). `VoltaShortcuts`가 단축어 앱에 노출되는지만 확인. 빌드 Phases에 "Extract App Intents Metadata" 단계 자동 존재 여부 확인 **(확인 필요 — 명칭)**.

## 7. 확인 필요 모음

- macOS Deployment 26.0 vs 26.x (사용 API 기준).
- CLI 헬퍼 Info.plist 임베드 설정 키 명칭, Copy Files Destination 정확도.
- Personal Team의 SMAppService daemon 등록 가능 범위.
- App Sandbox on 상태에서 IOKit SMC 읽기 가부(앱 sandbox 최종 결정).
- "Extract App Intents Metadata" 빌드 단계 자동 생성/명칭.

> SMC 키/매직값 등 하드웨어 관련 검증은 `user-test-checklist.md` 참조.
