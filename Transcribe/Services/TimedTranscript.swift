import Foundation

/// Pure, framework-free operations over timed transcript segments: active-word
/// lookup for highlighting, edit/timing reconciliation, text rebuild, and
/// timestamp-keyed restore from an original snapshot.
enum TimedTranscript {

    struct WordLocation: Equatable {
        let segmentIndex: Int
        let wordIndex: Int
    }

    /// The word that should be highlighted at `time`: the last word whose start
    /// is <= time. Returns nil before the first word. In a gap between words it
    /// stays on the previous word.
    static func activeWord(in segments: [TranscriptionSegmentData], at time: TimeInterval) -> WordLocation? {
        var result: WordLocation?
        for (s, segment) in segments.enumerated() {
            guard let words = segment.words else { continue }
            for (i, word) in words.enumerated() {
                if word.start <= time {
                    result = WordLocation(segmentIndex: s, wordIndex: i)
                } else {
                    return result
                }
            }
        }
        return result
    }

    /// Where a turn sits relative to the playhead. Rows away from the playhead
    /// get the stable `.spoken`/`.upcoming` cases so 10 Hz playback ticks don't
    /// invalidate them — only the active turn's row changes per tick.
    enum PlaybackPhase: Equatable {
        case upcoming
        case active(TimeInterval)
        case spoken

        static func of(start: TimeInterval, end: TimeInterval, at time: TimeInterval) -> PlaybackPhase {
            if time < start { return .upcoming }
            if time >= end { return .spoken }
            return .active(time)
        }

        /// Time to feed per-word coloring: past turns render fully spoken,
        /// future turns fully unspoken, the active turn follows the playhead.
        var effectiveTime: TimeInterval {
            switch self {
            case .upcoming: return -.infinity
            case .active(let t): return t
            case .spoken: return .infinity
            }
        }
    }

    /// Scroll-target view ID for a word — the single source of the ID format,
    /// shared by WordFlowView (`.id`) and the follow-playback scroller.
    static func wordID(segment: Int, word: Int) -> String {
        "w-\(segment)-\(word)"
    }

    /// The ID follow-playback should scroll to at `time`, or nil when no scroll
    /// is wanted: before the first word, or when the active word is unchanged
    /// since the last scroll (so 10 Hz playback ticks don't restart the scroll
    /// animation every tick).
    static func followScrollTarget(in segments: [TranscriptionSegmentData], at time: TimeInterval, lastTargetID: String?) -> String? {
        guard let active = activeWord(in: segments, at: time) else { return nil }
        let id = wordID(segment: active.segmentIndex, word: active.wordIndex)
        return id == lastTargetID ? nil : id
    }

    /// Full transcript text rebuilt from segments (after edits).
    static func rebuildText(from segments: [TranscriptionSegmentData]) -> String {
        segments
            .map { $0.text.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Re-tokenizes a sentence edit into words against the segment's [start, end].
    /// Same word count → keep original timings 1:1. Different count → distribute
    /// the segment span evenly and flag timingApproximate.
    static func reconcileSentence(_ segment: TranscriptionSegmentData, newText: String) -> TranscriptionSegmentData {
        let tokens = newText.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        var updated = segment
        updated.text = tokens.joined(separator: " ")

        let oldWords = segment.words ?? []
        if tokens.count == oldWords.count && !tokens.isEmpty {
            updated.words = zip(tokens, oldWords).map { token, old in
                WordTimestamp(word: token, start: old.start, end: old.end, confidence: old.confidence)
            }
            updated.timingApproximate = segment.timingApproximate
            return updated
        }

        guard !tokens.isEmpty else { updated.words = []; return updated }
        let span = max(0, segment.end - segment.start)
        let step = span / Double(tokens.count)
        updated.words = tokens.enumerated().map { i, token in
            let start = segment.start + step * Double(i)
            let end = (i == tokens.count - 1) ? segment.end : start + step
            return WordTimestamp(word: token, start: start, end: end, confidence: 1.0)
        }
        updated.timingApproximate = true
        return updated
    }

    /// The original word whose time range contains the midpoint of `edited`.
    static func originalWord(in original: [TranscriptionSegmentData], atMidpointOf edited: WordTimestamp) -> WordTimestamp? {
        let mid = (edited.start + edited.end) / 2
        for segment in original {
            for word in segment.words ?? [] where word.start <= mid && mid <= word.end {
                return word
            }
        }
        return original.flatMap { $0.words ?? [] }.max { a, b in
            overlap(a.start, a.end, edited.start, edited.end) < overlap(b.start, b.end, edited.start, edited.end)
        }
    }

    /// The original segment with the greatest time overlap with `edited`.
    static func originalSegment(in original: [TranscriptionSegmentData], overlapping edited: TranscriptionSegmentData) -> TranscriptionSegmentData? {
        original.max { a, b in
            overlap(a.start, a.end, edited.start, edited.end) < overlap(b.start, b.end, edited.start, edited.end)
        }.flatMap { best in
            overlap(best.start, best.end, edited.start, edited.end) > 0 ? best : nil
        }
    }

    private static func overlap(_ a0: Double, _ a1: Double, _ b0: Double, _ b1: Double) -> Double {
        max(0, min(a1, b1) - max(a0, b0))
    }
}
