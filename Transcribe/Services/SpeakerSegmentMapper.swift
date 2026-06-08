import Foundation

/// Pure, framework-free mapping of raw diarizer output rows into ordered
/// `SpeakerSegment`s with stable "Speaker N" labels (first-appearance order).
/// Keeps `DiarizationService`'s FluidAudio-specific extraction separate from the
/// labeling logic so the latter is unit-testable.
enum SpeakerSegmentMapper {

    struct Row: Equatable {
        let speakerIndex: Int
        let start: TimeInterval
        let end: TimeInterval
    }

    /// Sorts rows by start time and relabels each distinct `speakerIndex` to
    /// "Speaker 1/2/3…" in the order speakers first appear on the timeline.
    static func map(_ rows: [Row]) -> [SpeakerSegment] {
        let sorted = rows.sorted { $0.start < $1.start }
        var labels: [Int: String] = [:]
        var next = 1
        return sorted.map { row in
            let label: String
            if let existing = labels[row.speakerIndex] {
                label = existing
            } else {
                label = "Speaker \(next)"
                labels[row.speakerIndex] = label
                next += 1
            }
            return SpeakerSegment(speakerLabel: label, start: row.start, end: row.end)
        }
    }
}
