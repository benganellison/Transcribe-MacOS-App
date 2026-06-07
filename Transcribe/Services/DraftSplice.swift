import Foundation

/// Pure helpers for the progressive draft→Whisper splice: keep the part of the
/// draft that Whisper hasn't reached yet, and build the combined display text.
enum DraftSplice {

    /// Draft segments not yet covered by Whisper: those whose END is past `t`
    /// (a segment straddling the boundary is kept so no words are dropped).
    static func tailDraft(_ draft: [TranscriptionSegmentData], after t: TimeInterval) -> [TranscriptionSegmentData] {
        draft.filter { $0.end > t }
    }

    /// Combined plain text: Whisper's covered text + the remaining draft tail.
    static func combinedText(whisperText: String, draft: [TranscriptionSegmentData], coveredUntil t: TimeInterval) -> String {
        let tail = tailDraft(draft, after: t).map { $0.text.trimmingCharacters(in: .whitespaces) }
        return ([whisperText.trimmingCharacters(in: .whitespaces)] + tail)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
