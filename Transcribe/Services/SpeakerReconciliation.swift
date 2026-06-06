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

    /// Relabels a single utterance (by id) to `target`, then re-groups.
    static func reassign(_ utterances: [DiarizedUtterance], utteranceID: UUID, to target: String) -> [DiarizedUtterance] {
        let relabeled = utterances.map { u -> DiarizedUtterance in
            guard u.id == utteranceID else { return u }
            return relabel(u, to: target)
        }
        return regroupAdjacent(relabeled)
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
