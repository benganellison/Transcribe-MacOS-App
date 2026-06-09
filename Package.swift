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
        // WhisperKit (speech-to-text) + SpeakerKit (Pyannote v4 diarization) ship together
        // in the Argmax OSS umbrella package.
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.0.0"),

        // YouTubeKit for YouTube video downloading
        .package(url: "https://github.com/alexeichhorn/YouTubeKit.git", from: "0.3.0"),

        // FluidAudio for the Parakeet instant-draft ASR (CoreML)
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4"),
    ],
    targets: [
        .target(
            name: "Transcribe",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "SpeakerKit", package: "argmax-oss-swift"),
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