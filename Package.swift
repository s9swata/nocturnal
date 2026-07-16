// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Nocturnal",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "NocturnalCore", targets: ["NocturnalCore"]),
        .executable(name: "Nocturnal", targets: ["Nocturnal"]),
        .executable(name: "nocturnal-hook-forwarder", targets: ["nocturnal-hook-forwarder"]),
        .executable(name: "nocturnal-setup", targets: ["nocturnal-setup"]),
    ],
    dependencies: [
        // SPM-vendored Swift Testing works under Command Line Tools (no full Xcode).
        // System `import Testing` alone fails because TestingMacros are not on the
        // default plugin path for XCTest-less CLT toolchains.
        .package(url: "https://github.com/apple/swift-testing.git", from: "6.0.0"),
    ],
    targets: [
        .target(
            name: "NocturnalCore",
            path: "Sources/NocturnalCore",
            // Bundle the OpenCode plugin template so packaged nocturnal-setup
            // never falls back to an empty stub when #filePath is unavailable.
            resources: [
                .copy("Hooks/OpenCodeBridge.plugin.js"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .executableTarget(
            name: "Nocturnal",
            dependencies: ["NocturnalCore"],
            path: "Sources/Nocturnal",
            resources: [
                // Brand marks (owl + app icon source). Packaged .icns is built by package_app.sh.
                .process("Resources"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .executableTarget(
            name: "nocturnal-hook-forwarder",
            dependencies: ["NocturnalCore"],
            path: "Sources/nocturnal-hook-forwarder",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .executableTarget(
            name: "nocturnal-setup",
            dependencies: ["NocturnalCore"],
            path: "Sources/nocturnal-setup",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "NocturnalCoreTests",
            dependencies: [
                "NocturnalCore",
                .product(name: "Testing", package: "swift-testing"),
            ],
            path: "Tests/NocturnalCoreTests",
            // Fixtures/ lives at repo root; tests resolve them via #filePath
            // (see TestSupport.fixtureData). Avoid SPM `.copy("../../…")` which
            // fails with "unhandled resource" under some CLT SwiftPM versions.
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
