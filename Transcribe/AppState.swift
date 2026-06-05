import SwiftUI

class AppState: ObservableObject {
    @Published var currentTranscriptionURL: URL?
    @Published var showTranscriptionView = false
    @Published var showRecordingView = false
    @Published var showSystemAudioView = false
    @Published var showRecordingLibrary = false
    @Published var currentRecordingID: UUID?
    /// Stable id (filename) of the voice memo being transcribed, used to cache/reload
    /// its transcription. Nil when the open audio isn't a voice memo.
    @Published var currentVoiceMemoID: String?

    func openFileForTranscription(_ url: URL) {
        currentRecordingID = nil
        currentVoiceMemoID = nil
        currentTranscriptionURL = url
        showTranscriptionView = true
    }

    func openRecordingForTranscription(_ url: URL, recordingID: UUID) {
        currentRecordingID = recordingID
        currentVoiceMemoID = nil
        currentTranscriptionURL = url
        showTranscriptionView = true
    }

    func openVoiceMemoForTranscription(_ url: URL, voiceMemoID: String) {
        currentRecordingID = nil
        currentVoiceMemoID = voiceMemoID
        currentTranscriptionURL = url
        showTranscriptionView = true
    }
}