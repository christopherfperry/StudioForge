// swift-tools-version:5.9
// StudioForge — native macOS multi-track DAW.
// The DSP / beat / preset / project / render modules are platform-independent (Foundation only)
// so they can be unit-tested anywhere with `swift test`. CoreAudio / CoreMIDI / AVFoundation /
// SwiftUI code is guarded with `#if os(macOS)`.
import PackageDescription

let package = Package(
    name: "StudioForge",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "StudioForge", targets: ["StudioForgeApp"]),
        .library(name: "StudioForgeKit", targets: [
            "SFCore", "SFEffects", "SFInstruments", "SFPresets", "SFBeatGen",
            "SFSeparation", "SFProject", "SFEngine", "SFExport", "SFUI",
        ]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.2.0"),
    ],
    targets: [
        .target(name: "SFCore", dependencies: [.product(name: "Atomics", package: "swift-atomics")]),
        .target(name: "SFEffects", dependencies: ["SFCore"]),
        .target(name: "SFInstruments", dependencies: ["SFCore", "SFEffects"]),
        .target(name: "SFPresets", dependencies: ["SFCore", "SFEffects", "SFInstruments", "SFProject"],
                resources: [.copy("Resources/Presets")]),
        .target(name: "SFBeatGen", dependencies: ["SFCore"],
                resources: [.copy("Resources/BeatStyles")]),
        .target(name: "SFSeparation", dependencies: ["SFCore"]),
        .target(name: "SFProject", dependencies: ["SFCore"]),
        .target(name: "SFEngine", dependencies: [
            "SFCore", "SFEffects", "SFInstruments", "SFProject",
            .product(name: "Atomics", package: "swift-atomics"),
        ]),
        .target(name: "SFExport", dependencies: ["SFCore", "SFEngine", "SFProject", "SFBeatGen"]),
        .target(name: "SFUI", dependencies: [
            "SFCore", "SFEffects", "SFInstruments", "SFPresets", "SFBeatGen",
            "SFSeparation", "SFProject", "SFEngine", "SFExport",
        ]),
        .executableTarget(name: "StudioForgeApp", dependencies: ["SFUI", "SFCore", "SFProject"]),
        .testTarget(name: "StudioForgeTests", dependencies: [
            "SFCore", "SFEffects", "SFInstruments", "SFPresets", "SFBeatGen",
            "SFSeparation", "SFProject", "SFEngine", "SFExport",
        ]),
    ]
)
