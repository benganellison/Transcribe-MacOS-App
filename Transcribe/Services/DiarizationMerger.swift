import Foundation

/// Pure, framework-free merge of transcript words with speaker blocks.
/// Assigns each word to the speaker active at its midpoint and groups
/// consecutive same-speaker words into utterances.
actor DiarizationMerger {

    /// Minimal word timing the merger needs (decoupled from WhisperKit types).
    struct Word: Equatable {
        let text: String
        let start: TimeInterval
        let end: TimeInterval
    }

    func merge(words: [Word], speakers: [SpeakerSegment]) -> [DiarizedUtterance] {
        guard !words.isEmpty else { return [] }

        var utterances: [DiarizedUtterance] = []
        var lastSpeaker: String? = nil

        for word in words {
            let speaker = speakerLabel(for: word, in: speakers, fallback: lastSpeaker)
            lastSpeaker = speaker

            if let current = utterances.last, current.speakerID == speaker {
                // Extend the current utterance with this word.
                utterances[utterances.count - 1] = DiarizedUtterance(
                    id: current.id,
                    speakerID: current.speakerID,
                    displayName: current.displayName,
                    text: current.text + " " + word.text,
                    startTime: current.startTime,
                    endTime: word.end
                )
            } else {
                utterances.append(DiarizedUtterance(
                    speakerID: speaker,
                    text: word.text,
                    startTime: word.start,
                    endTime: word.end
                ))
            }
        }
        return utterances
    }

    /// Picks the speaker whose block contains the word midpoint; on a tie/boundary
    /// the earlier block wins (blocks assumed sorted by start). Falls back to the
    /// greatest-overlap block, then to the previous word's speaker, then "Speaker 1".
    private func speakerLabel(for word: Word, in speakers: [SpeakerSegment], fallback: String?) -> String {
        guard !speakers.isEmpty else { return fallback ?? "Speaker 1" }
        let midpoint = (word.start + word.end) / 2.0

        // Containment using half-open (start, end] so a midpoint landing exactly on
        // a boundary is attributed to the earlier block (whose interval ends there),
        // not the later block (whose interval starts there).
        if let containing = speakers.first(where: { midpoint > $0.start && midpoint <= $0.end }) {
            return containing.speakerLabel
        }
        // Otherwise the block with the greatest temporal overlap with the word span.
        let best = speakers.max { overlap(word, $0) < overlap(word, $1) }
        if let best, overlap(word, best) > 0 {
            return best.speakerLabel
        }
        // No containment and no overlap (word sits in a gap): stick with the
        // previous word's speaker so a brief silence doesn't fragment a turn.
        return fallback ?? speakers[0].speakerLabel
    }

    private func overlap(_ word: Word, _ block: SpeakerSegment) -> TimeInterval {
        max(0, min(word.end, block.end) - max(word.start, block.start))
    }
}
