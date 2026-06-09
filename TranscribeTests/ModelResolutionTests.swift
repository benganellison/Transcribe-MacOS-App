import Foundation
import Testing
@testable import Transcribe

@MainActor
struct ModelResolutionTests {
    private func resolve(_ selected: String, _ lang: String) -> String {
        TranscriptionService.resolveEffectiveModel(selected: selected, languageCode: lang)
    }

    @Test func autoPicksLargeByLanguage() {
        #expect(resolve("auto", "sv") == "kb_whisper-large-coreml")
        #expect(resolve("auto", "en") == "openai_whisper-large-v3")
        #expect(resolve("auto", "auto") == "openai_whisper-large-v3")   // unknown → multilingual
    }

    @Test func kbSwapsToSameSizeOpenAIForNonSwedish() {
        #expect(resolve("kb_whisper-base-coreml", "en") == "openai_whisper-base")
        #expect(resolve("kb_whisper-small-coreml", "en") == "openai_whisper-small")
        #expect(resolve("kb_whisper-medium-coreml", "en") == "openai_whisper-medium")
        #expect(resolve("kb_whisper-large-coreml", "en") == "openai_whisper-large-v3")  // large → v3
    }

    @Test func kbKeptForSwedish() {
        #expect(resolve("kb_whisper-small-coreml", "sv") == "kb_whisper-small-coreml")
        #expect(resolve("kb_whisper-large-coreml", "sv") == "kb_whisper-large-coreml")
    }

    @Test func explicitNonKBModelRespected() {
        #expect(resolve("openai_whisper-medium", "sv") == "openai_whisper-medium")
        #expect(resolve("openai_whisper-large-v2", "en") == "openai_whisper-large-v2")
    }
}
