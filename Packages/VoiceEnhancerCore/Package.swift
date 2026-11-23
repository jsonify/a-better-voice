// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VoiceEnhancerCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "VoiceEnhancerCore", targets: ["VoiceEnhancerCore"]),
        .executable(name: "voice-enhance", targets: ["voice-enhance"]),
    ],
    targets: [
        .target(name: "VoiceEnhancerCore"),
        .executableTarget(name: "voice-enhance", dependencies: ["VoiceEnhancerCore"]),
        .testTarget(name: "VoiceEnhancerCoreTests", dependencies: ["VoiceEnhancerCore"]),
    ]
)
