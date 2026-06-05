import Foundation

/// A contiguous block of audio attributed to one speaker by the diarizer.
/// Framework-agnostic wrapper so FluidAudio types never leak past DiarizationService.
struct SpeakerSegment: Equatable {
    let speakerLabel: String   // e.g. "Speaker 1"
    let start: TimeInterval
    let end: TimeInterval
}

/// One speaker turn of transcribed text, ready for the UI and for persistence.
struct DiarizedUtterance: Identifiable, Equatable, Codable {
    let id: UUID
    let speakerID: String      // stable label from the diarizer, e.g. "Speaker 1"
    var displayName: String    // shown in UI; defaults to speakerID, overridden by rename/LLM
    var text: String
    let startTime: TimeInterval
    let endTime: TimeInterval

    init(
        id: UUID = UUID(),
        speakerID: String,
        displayName: String? = nil,
        text: String,
        startTime: TimeInterval,
        endTime: TimeInterval
    ) {
        self.id = id
        self.speakerID = speakerID
        self.displayName = displayName ?? speakerID
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
    }
}
