# Local Development

This guide covers building, running, and testing Transcribe locally — including how to produce a build you can launch and test by hand.

For a high-level overview of the codebase, see [ARCHITECTURE.md](ARCHITECTURE.md).

## Prerequisites

- **macOS 26 (Tahoe) or later** on **Apple Silicon (M1+)**
- **Xcode 26** with the macOS 26 SDK and Command Line Tools
- A network connection on first launch (the default KB Whisper Small model downloads automatically)

Verify your toolchain:

```bash
xcodebuild -version
xcode-select -p
```

## Get the code

```bash
git clone https://github.com/mickekring/Transcribe-MacOS-App.git
cd Transcribe-MacOS-App
```

Swift Package Manager dependencies (WhisperKit, YouTubeKit) resolve automatically on the first build.

## Build

Always build from the command line. Building from the Xcode UI currently fails with an `___llvm_profile_runtime` undefined symbol error — an Xcode 26 bug where `CLANG_COVERAGE_MAPPING` defaults to `YES` and adds coverage instrumentation to a pure-C SPM dependency (yyjson, a transitive dependency of WhisperKit) without linking the profiling runtime. Disabling coverage mapping avoids it:

```bash
xcodebuild build -scheme Transcribe CLANG_COVERAGE_MAPPING=NO
```

## Build and run for human testing

Build a debug app and launch it so you can click through the UI yourself.

**1. Build the app:**

```bash
xcodebuild build -scheme Transcribe -configuration Debug CLANG_COVERAGE_MAPPING=NO
```

**2. Find the built app.** `xcodebuild` writes products into `DerivedData`. Resolve the exact path with:

```bash
APP_PATH="$(xcodebuild -scheme Transcribe -configuration Debug -showBuildSettings 2>/dev/null \
  | awk '/ BUILT_PRODUCTS_DIR /{print $3}')/Transcribe.app"
echo "$APP_PATH"
```

**3. Launch it:**

```bash
open "$APP_PATH"
```

Alternatively, open the project in Xcode and press **⌘R** to build-and-run, or right-click `Transcribe.app` under **Products** → **Show in Finder**.

```bash
open Transcribe.xcodeproj
```

### What to test by hand

Some features can't be covered by unit tests because they need real system permissions, audio hardware, or other apps' data:

- **Recording** — microphone capture, live level meter, and input-device selection.
- **System audio capture** — ScreenCaptureKit prompts for "Screen & System Audio Recording" permission on first use; you may need to restart the app after granting it.
- **Voice Memos library** — connect your Voice Memos folder, confirm recordings show their location-based titles, and double-click one to transcribe it. This reads another app's sandbox container, so it exercises the security-scoped bookmark path.
- **Transcription** — run a short clip through a local model end to end and confirm the transcript saves back to the recording.

## Run the tests

The unit tests live in the `TranscribeTests` target. Run just that target (the `TranscribeUITests` target drives the full UI and is slower):

```bash
xcodebuild test -scheme Transcribe -destination 'platform=macOS' \
  -only-testing:TranscribeTests CLANG_COVERAGE_MAPPING=NO
```

To run everything, including UI tests:

```bash
xcodebuild test -scheme Transcribe -destination 'platform=macOS' CLANG_COVERAGE_MAPPING=NO
```

## Dependencies and versions

Dependencies are declared in the Xcode project (`Transcribe.xcodeproj`) and mirrored in `Package.swift`:

- **[WhisperKit](https://github.com/argmaxinc/WhisperKit)** — on-device speech recognition (CoreML). The project currently tracks WhisperKit's `main` branch. If you run **File → Packages → Update to Latest Package Versions**, newer `main` commits can introduce breaking API changes; pin to a release tag if you need a reproducible build.
- **[YouTubeKit](https://github.com/alexeichhorn/YouTubeKit)** — YouTube audio downloading.

## Troubleshooting

- **`___llvm_profile_runtime` undefined symbol** — you built from the Xcode UI, or omitted `CLANG_COVERAGE_MAPPING=NO`. Build from the command line with the flag (see above).
- **WhisperKit compile error mentioning `DecodingOptions` or a confusing `AsyncThrowingStream` closure error** — WhisperKit's `main` branch changed its API. Check the `DecodingOptions(...)` call in `Transcribe/WhisperKitService.swift` against the resolved WhisperKit source, or pin WhisperKit to a known-good tag.
- **Code-signing failures in a CI or headless environment** — disable signing for local/CI builds:

  ```bash
  xcodebuild build -scheme Transcribe CLANG_COVERAGE_MAPPING=NO \
    CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
  ```

- **Model won't download on first launch** — confirm network access; the default KB Whisper Small model is fetched from [Hugging Face](https://huggingface.co/mickekringai/kb-whisper-coreml) on first run.
