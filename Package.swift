// swift-tools-version: 6.2
import PackageDescription

let core: [SwiftSetting] = [
    .enableExperimentalFeature("Lifetimes"),
]

let package = Package(
    name: "swiftty",
    platforms: [.macOS("27.0"), .iOS("27.0"), .macCatalyst("27.0"), .visionOS("27.0")],
    products: [
        .library(name: "SwifttyCore", targets: ["SwifttyCore"]),
        .library(name: "SwifttyMobile", targets: ["SwifttyMobile"]),
        .executable(name: "swiftty", targets: ["Swiftty"]),
        .executable(name: "swiftty-bench", targets: ["SwifttyBench"]),
    ],
    targets: [
        .target(
            name: "SwifttyCore",
            resources: [.copy("Renderer/Shaders.metal")],
            swiftSettings: core,
        ),
        // Test/bench-only allocation counter built on libmalloc's logger hook.
        .target(name: "CAllocCounter"),
        .executableTarget(name: "Swiftty", dependencies: ["SwifttyCore"]),
        // UIKit frontend (iOS/iPadOS). Its view code compiles only where UIKit
        // exists; the platform-neutral input logic and demo source build
        // everywhere so their tests run on macOS too.
        .target(name: "SwifttyMobile", dependencies: ["SwifttyCore"]),
        .executableTarget(
            name: "SwifttyBench",
            dependencies: ["SwifttyCore", "CAllocCounter"],
            swiftSettings: core,
        ),
        .testTarget(
            name: "SwifttyCoreTests",
            dependencies: ["SwifttyCore", "CAllocCounter"],
            swiftSettings: core,
        ),
        .testTarget(name: "SwifttyMobileTests", dependencies: ["SwifttyMobile", "SwifttyCore"]),
    ],
)
