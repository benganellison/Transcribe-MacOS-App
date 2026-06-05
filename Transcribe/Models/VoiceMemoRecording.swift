import Foundation

struct VoiceMemoRecording: Identifiable {
    let id: String
    let fileURL: URL
    let name: String
    let date: Date
    let duration: TimeInterval
    let fileSize: Int64
    
    init(fileURL: URL, name: String, date: Date, duration: TimeInterval, fileSize: Int64) {
        self.id = fileURL.lastPathComponent
        self.fileURL = fileURL
        self.name = name
        self.date = date
        self.duration = duration
        self.fileSize = fileSize
    }
}

/// Cached transcription for a voice memo, persisted in a sidecar store so reopening
/// the memo doesn't re-transcribe it. Keyed by the memo's stable file id.
struct VoiceMemoTranscription: Codable {
    var text: String
    var segments: [TranscriptionSegmentData]
    var model: String
    var date: Date
    /// Diarization results, persisted alongside the transcription. Optional so
    /// older cache files (text-only) still decode.
    var diarizedUtterances: [DiarizedUtterance]?
    var speakerNames: [String: String]?
}
