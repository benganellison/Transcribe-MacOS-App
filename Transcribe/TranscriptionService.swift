import Foundation
import Combine

// Transcription update structure for streaming
struct TranscriptionUpdate {
    let text: String
    let progress: Double
    let segments: [TranscriptionSegmentData]
    let isComplete: Bool
    var coveredUntil: TimeInterval = 0
}

@MainActor
class TranscriptionService {
    private let modelManager = ModelManager.shared
    private let languageManager = LanguageManager.shared
    private var whisperKitService: WhisperKitService?
    
    /// Stops the in-progress WhisperKit transcription early.
    func cancel() {
        whisperKitService?.cancel()
    }

    /// Resolves the model that will actually run from the user's selection + language.
    /// KB-Whisper is fine-tuned for Swedish and effectively only outputs Swedish, so:
    /// - "auto" model → KB for Swedish, multilingual OpenAI otherwise.
    /// - a KB model with a non-Swedish (or auto) language → multilingual OpenAI instead.
    /// Everything else is used as-is.
    static let multilingualDefaultModel = "openai_whisper-large-v3"
    static let swedishDefaultModel = "kb_whisper-large-coreml"

    static func resolveEffectiveModel(selected: String, languageCode: String) -> String {
        let isSwedish = (languageCode == "sv")
        if selected == "auto" {
            // "Auto" = best-quality (large) by language.
            return isSwedish ? swedishDefaultModel : multilingualDefaultModel
        }
        // KB is Swedish-only in practice; for non-Swedish, keep the chosen SIZE but swap
        // to the same-size OpenAI (multilingual) model. large → v3 (newer/better).
        if selected.hasPrefix("kb_whisper-") && !isSwedish {
            switch selected {
            case "kb_whisper-base-coreml":   return "openai_whisper-base"
            case "kb_whisper-small-coreml":  return "openai_whisper-small"
            case "kb_whisper-medium-coreml": return "openai_whisper-medium"
            case "kb_whisper-large-coreml":  return "openai_whisper-large-v3"
            default:                          return multilingualDefaultModel
            }
        }
        return selected
    }

    private func currentEffectiveModel() -> String {
        let selected = UserDefaults.standard.string(forKey: "selectedTranscriptionModel") ?? ""
        return Self.resolveEffectiveModel(selected: selected, languageCode: languageManager.selectedLanguage.code)
    }

    /// Loads (and compiles) the effective WhisperKit model ahead of time so the first
    /// transcription window doesn't pay the multi-minute load/compile cost.
    func prewarm() async {
        let modelId = currentEffectiveModel()
        guard modelId.hasPrefix("kb_whisper-") || modelId.hasPrefix("openai_whisper-") else { return }
        if whisperKitService == nil {
            whisperKitService = WhisperKitService()
        }
        if whisperKitService?.currentModel == modelId { return }  // already loaded
        try? await whisperKitService?.initialize(modelId: modelId)
    }

    func transcribe(fileURL: URL, forceWordTimestamps: Bool = false) -> AsyncThrowingStream<TranscriptionUpdate, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    // Resolve the effective model (handles "auto" + KB→multilingual).
                    guard let rawModel = UserDefaults.standard.string(forKey: "selectedTranscriptionModel"),
                          !rawModel.isEmpty else {
                        throw TranscriptionError.noModelSelected
                    }
                    let selectedModel = Self.resolveEffectiveModel(selected: rawModel, languageCode: languageManager.selectedLanguage.code)

                    if selectedModel.starts(with: "kb_whisper-") ||  // KB CoreML models
                       selectedModel.starts(with: "openai_whisper-") {
                        // Use WhisperKit for standard Whisper models and KB CoreML models
                        try await transcribeWithWhisperKit(
                            fileURL: fileURL,
                            modelId: selectedModel,
                            forceWordTimestamps: forceWordTimestamps,
                            continuation: continuation
                        )
                    } else if selectedModel.starts(with: "cloud-") {
                        // Use cloud model (OpenAI API)
                        try await transcribeWithCloudModel(
                            fileURL: fileURL,
                            modelId: selectedModel,
                            continuation: continuation
                        )
                    } else {
                        throw TranscriptionError.unsupportedModel
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    
    private func transcribeWithWhisperKit(
        fileURL: URL,
        modelId: String,
        forceWordTimestamps: Bool = false,
        continuation: AsyncThrowingStream<TranscriptionUpdate, Error>.Continuation
    ) async throws {
        // Initialize WhisperKit service if needed
        if whisperKitService == nil {
            whisperKitService = WhisperKitService()
        }
        
        // Use WhisperKit for standard models
        guard let service = whisperKitService else {
            throw TranscriptionError.modelNotFound
        }
        
        // If the file is a video container or non-native audio format,
        // extract the audio track to a temporary .m4a first.
        let preprocessor = AudioPreprocessor.shared
        let needsConversion = preprocessor.needsConversionForWhisperKit(url: fileURL)
        var audioURL = fileURL
        
        if needsConversion {
            continuation.yield(TranscriptionUpdate(
                text: NSLocalizedString("converting_audio_format", comment: ""),
                progress: 0.02,
                segments: [],
                isComplete: false
            ))
            audioURL = try await preprocessor.extractAudioForWhisperKit(url: fileURL)
        }
        
        defer {
            // Clean up the temporary file if we created one
            if needsConversion {
                try? FileManager.default.removeItem(at: audioURL)
            }
        }
        
        // Get the selected language
        let selectedLanguage = languageManager.selectedLanguage.code
        
        // Stream transcription updates with model and language
        for try await update in service.transcribe(fileURL: audioURL, modelId: modelId, language: selectedLanguage, forceWordTimestamps: forceWordTimestamps) {
            continuation.yield(update)
            
            if update.isComplete {
                continuation.finish()
                return
            }
        }
        
        // If the loop exits without isComplete, still finish the stream
        continuation.finish()
    }
    
    private func transcribeWithCloudModel(
        fileURL: URL,
        modelId: String,
        continuation: AsyncThrowingStream<TranscriptionUpdate, Error>.Continuation
    ) async throws {
        // Implementation for cloud models (OpenAI, Groq, etc.)
        // This would use the API keys stored in UserDefaults
        continuation.yield(TranscriptionUpdate(
            text: "Cloud transcription not yet implemented",
            progress: 1.0,
            segments: [],
            isComplete: true
        ))
        continuation.finish()
    }
    
    func cancelTranscription() {
        // WhisperKit handles cancellation internally
    }
}

enum TranscriptionError: LocalizedError {
    case noModelSelected
    case modelNotFound
    case unsupportedModel
    
    var errorDescription: String? {
        switch self {
        case .noModelSelected:
            return "No transcription model selected"
        case .modelNotFound:
            return "Selected model not found. Please download it first."
        case .unsupportedModel:
            return "Unsupported model type"
        }
    }
}