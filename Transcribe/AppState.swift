import SwiftUI

class AppState: ObservableObject {
    @Published var currentTranscriptionURL: URL?
    @Published var showTranscriptionView = false
    @Published var showRecordingView = false
    @Published var showSystemAudioView = false
    @Published var showRecordingLibrary = false
    @Published var currentRecordingID: UUID?
    
    func openFileForTranscription(_ url: URL) {
        currentRecordingID = nil
        currentTranscriptionURL = url
        showTranscriptionView = true
    }
    
    func openRecordingForTranscription(_ url: URL, recordingID: UUID) {
        currentRecordingID = recordingID
        currentTranscriptionURL = url
        showTranscriptionView = true
    }
}