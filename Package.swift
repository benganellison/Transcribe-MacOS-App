// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Transcribe",
    defaultLocalization: "sv",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .library(
            name: "Transcribe",
            targets: ["Transcribe"]
        )
    ],
    dependencies: [
        // WhisperKit for on-device speech recognition
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.5.0"),

        // YouTubeKit for YouTube video downloading
        .package(url: "https://github.com/alexeichhorn/YouTubeKit.git", from: "0.3.0"),

        // FluidAudio for on-device speaker diarization (CoreML)
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4"),
    ],
    targets: [
        .target(
            name: "Transcribe",
            dependencies: [
                "WhisperKit",
                "YouTubeKit",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Transcribe",
            exclude: [
                "Info.plist",
                "Transcribe.entitlements",
                "Resources/whisper"
            ]
        ),
        .testTarget(
            name: "TranscribeTests",
            dependencies: ["Transcribe"]
        )
    ]
)