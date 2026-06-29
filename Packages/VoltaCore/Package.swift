// swift-tools-version: 6.0
import PackageDescription

// VoltaCore: 앱과 root 헬퍼 데몬이 공유하는 코어 레이어.
// - SMC 접근/디코딩, 정책 상태머신, XPC 프로토콜, 공용 모델을 담는다.
// - 플랫폼 의존(IOKit 등) 코드는 #if canImport 으로 가드한다.
let package = Package(
    name: "VoltaCore",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .library(name: "VoltaCore", targets: ["VoltaCore"])
    ],
    targets: [
        .target(
            name: "VoltaCore",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "VoltaCoreTests",
            dependencies: ["VoltaCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
