import Foundation

/// Pure, framework-free speaker-label reconciliation over diarized utterances:
/// merge two speakers, reassign a single turn, and re-group adjacent same-speaker
/// utterances. No UI, no audio — unit-tested.
enum SpeakerReconciliation {

    /// Distinct speaker IDs in first-appearance order (for menus).
    static func distinctSpeakers(in utterances: [DiarizedUtterance]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for u in utterances where !seen.contains(u.speakerID) {
            seen.insert(u.speakerID)
            result.append(u.speakerID)
        }
        return result
    }

    /// The next free "Speaker N" label (one past the highest existing number).
    static func nextSpeakerLabel(in utterances: [DiarizedUtterance]) -> String {
        let prefix = "Speaker "
        var maxN = 0
        for u in utterances where u.speakerID.hasPrefix(prefix) {
            if let n = Int(u.speakerID.dropFirst(prefix.count)) { maxN = max(maxN, n) }
        }
        return "\(prefix)\(maxN + 1)"
    }

    /// Merges consecutive same-speaker utterances into one, concatenating words/text
    /// and spanning first start → last end (input assumed in time order).
    static func regroupAdjacent(_ utterances: [DiarizedUtterance]) -> [DiarizedUtterance] {
        var result: [DiarizedUtterance] = []
        for u in utterances {
            if let last = result.last, last.speakerID == u.speakerID {
                let mergedWords = (last.words ?? []) + (u.words ?? [])
                let mergedText = [last.text, u.text]
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                result[result.count - 1] = DiarizedUtterance(
                    id: last.id,
                    speakerID: last.speakerID,
                    displayName: last.displayName,
                    text: mergedText,
                    startTime: last.startTime,
                    endTime: u.endTime,
                    words: mergedWords.isEmpty ? nil : mergedWords
                )
            } else {
                result.append(u)
            }
        }
        return result
    }

    /// Relabels every `source` utterance to `target`, then re-groups. No-op if source == target.
    static func merge(_ utterances: [DiarizedUtterance], from source: String, into target: String) -> [DiarizedUtterance] {
        guard source != target else { return utterances }
        let relabeled = utterances.map { u -> DiarizedUtterance in
            guard u.speakerID == source else { return u }
            return relabel(u, to: target)
        }
        return regroupAdjacent(relabeled)
    }

    /// Relabels a single utterance (by id) to `target`. Deliberately does NOT
    /// re-group: re-grouping would merge a manually-split turn back into its
    /// neighbors before the user finishes reassigning the pieces. (Use `merge`
    /// to coalesce a whole speaker.)
    static func reassign(_ utterances: [DiarizedUtterance], utteranceID: UUID, to target: String) -> [DiarizedUtterance] {
        utterances.map { u in
            u.id == utteranceID ? relabel(u, to: target) : u
        }
    }

    /// Splits the utterance with `utteranceID` into two at `beforeWordIndex` (the
    /// second piece starts at that word), keeping the same speaker and word timings.
    /// No-op if the utterance/words aren't found or the index isn't an interior split
    /// point (1..<wordCount). Used to break a turn the diarizer merged across speakers.
    static func splitUtterance(_ utterances: [DiarizedUtterance], utteranceID: UUID, beforeWordIndex: Int) -> [DiarizedUtterance] {
        guard let idx = utterances.firstIndex(where: { $0.id == utteranceID }) else { return utterances }
        let u = utterances[idx]
        guard let words = u.words, beforeWordIndex > 0, beforeWordIndex < words.count else { return utterances }
        let firstWords = Array(words[..<beforeWordIndex])
        let secondWords = Array(words[beforeWordIndex...])
        let first = makeUtterance(speaker: u.speakerID, displayName: u.displayName, words: firstWords, fallback: u)
        let second = makeUtterance(speaker: u.speakerID, displayName: u.displayName, words: secondWords, fallback: u)
        var result = utterances
        result.replaceSubrange(idx...idx, with: [first, second])
        return result
    }

    /// Joins the utterance with `utteranceID` into the immediately preceding utterance,
    /// adopting the previous turn's speaker. Combines two adjacent turns into one
    /// (the inverse of split). No-op if it's the first utterance or not found.
    static func joinWithPrevious(_ utterances: [DiarizedUtterance], utteranceID: UUID) -> [DiarizedUtterance] {
        guard let idx = utterances.firstIndex(where: { $0.id == utteranceID }), idx > 0 else { return utterances }
        let prev = utterances[idx - 1]
        let cur = utterances[idx]
        let words = (prev.words ?? []) + (cur.words ?? [])
        let text = [prev.text, cur.text]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let combined = DiarizedUtterance(
            id: prev.id,
            speakerID: prev.speakerID,
            displayName: prev.displayName,
            text: text,
            startTime: prev.startTime,
            endTime: cur.endTime,
            words: words.isEmpty ? nil : words
        )
        var result = utterances
        result.replaceSubrange((idx - 1)...idx, with: [combined])
        return result
    }

    private static func makeUtterance(speaker: String, displayName: String, words: [WordTimestamp], fallback: DiarizedUtterance) -> DiarizedUtterance {
        DiarizedUtterance(
            speakerID: speaker,
            displayName: displayName,
            text: words.map(\.word).joined(separator: " "),
            startTime: words.first?.start ?? fallback.startTime,
            endTime: words.last?.end ?? fallback.endTime,
            words: words
        )
    }

    private static func relabel(_ u: DiarizedUtterance, to target: String) -> DiarizedUtterance {
        DiarizedUtterance(
            id: u.id,
            speakerID: target,
            displayName: target,
            text: u.text,
            startTime: u.startTime,
            endTime: u.endTime,
            words: u.words
        )
    }
}
