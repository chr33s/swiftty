// swift-tools-version: 6.4
import PackageDescription

let core: [SwiftSetting] = [.enableExperimentalFeature("Lifetimes")]

let package = Package(
  name: "swiftty",
  platforms: [
    .macOS("27.0"), .iOS("27.0"), .macCatalyst("27.0"), .visionOS("27.0"),
  ],
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
    // UIKit views are conditional; shared frontend tests also run on macOS.
    .target(name: "SwifttyMobile", dependencies: ["SwifttyCore"]),
    .executableTarget(
      name: "SwifttyBench",
      dependencies: ["SwifttyCore", "CAllocCounter"],
      swiftSettings: core,
    ), .target(name: "TestSupport", path: "Tests/Support"),
    .executableTarget(
      name: "StorageBoundsProbe",
      dependencies: ["SwifttyCore"],
      path: "Tests/StorageBoundsProbe",
      swiftSettings: core
    ),
    .testTarget(
      name: "SwifttyCoreTests",
      dependencies: [
        "SwifttyCore", "CAllocCounter", "TestSupport", "StorageBoundsProbe",
      ],
      swiftSettings: core,
    ),
    .testTarget(
      name: "SwifttyMobileTests",
      dependencies: ["SwifttyMobile", "SwifttyCore", "TestSupport"],
      resources: [.copy("Fixtures")],
    ),
    .testTarget(
      name: "SwifttyAppTests",
      dependencies: ["Swiftty", "SwifttyCore", "TestSupport"]
    ),
  ],
)
