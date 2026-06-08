import Foundation

/// Pure, framework-free progressive refinement of diarized turns.
///
/// As Whisper streams accurate words front-to-back, this splices them into the
/// existing speaker turns **in place** — replacing the rough Parakeet draft words
/// in the covered region while keeping turn identity, speaker assignment, and any
/// user edits. It never re-clusters, so manual speaker fixes made during streaming
/// survive, and because each turn keeps its `id` the UI doesn't reflow.
enum TranscriptRefiner {

    /// Rebuilds each turn's words for the region Whisper has covered.
    ///
    /// - `turns`: current speaker turns (may include user splits/merges/reassigns).
    /// - `whisperWords`: cumulative accurate words produced so far (with timings).
    /// - `coveredUntil`: time up to which Whisper's output is authoritative.
    ///
    /// Per turn the new word list is: every **locked** (user-edited) word, plus the
    /// **covered** whisper words assigned to that turn (minus any overlapping a locked
    /// word), plus the **uncovered** draft tail still beyond `coveredUntil`. Turn
    /// `id`, `speakerID`, `displayName`, `startTime`, and `endTime` are preserved.
    static func refine(turns: [DiarizedUtterance], whisperWords: [WordTimestamp], coveredUntil: TimeInterval) -> [DiarizedUtterance] {
        guard !turns.isEmpty, !whisperWords.isEmpty else { return turns }

        // Assign each covered whisper word to a turn, mark it refined (white).
        var perTurn: [[WordTimestamp]] = Array(repeating: [], count: turns.count)
        for var w in whisperWords {
            let mid = (w.start + w.end) / 2
            guard mid <= coveredUntil else { continue }
            guard let idx = targetTurnIndex(for: w, in: turns) else { continue }
            w.refined = true
            perTurn[idx].append(w)
        }

        return turns.enumerated().map { idx, turn in
            let existing = turn.words ?? []
            let locked = existing.filter { $0.isLocked }
            let uncoveredDraft = existing.filter { !$0.isLocked && ($0.start + $0.end) / 2 > coveredUntil }
            // Locked edits win over refinement: drop whisper words overlapping them.
            let whisper = perTurn[idx].filter { ww in !locked.contains { lw in overlaps(ww, lw) } }

            var merged = locked + whisper + uncoveredDraft
            merged.sort { $0.start < $1.start }

            var updated = turn  // copy preserves id / speakerID / displayName / boundaries
            updated.words = merged
            updated.text = merged.map(\.word).joined(separator: " ")
            return updated
        }
    }

    /// Turn whose time-range contains the word midpoint; else greatest overlap; else
    /// nearest turn (word fell in a gap between turns).
    private static func targetTurnIndex(for word: WordTimestamp, in turns: [DiarizedUtterance]) -> Int? {
        let mid = (word.start + word.end) / 2
        if let i = turns.firstIndex(where: { mid > $0.startTime && mid <= $0.endTime }) {
            return i
        }
        var bestIdx: Int? = nil
        var bestOverlap = 0.0
        for (i, t) in turns.enumerated() {
            let o = max(0, min(word.end, t.endTime) - max(word.start, t.startTime))
            if o > bestOverlap { bestOverlap = o; bestIdx = i }
        }
        if let bestIdx { return bestIdx }
        return turns.enumerated().min(by: { distance(mid, $0.element) < distance(mid, $1.element) })?.offset
    }

    private static func distance(_ t: TimeInterval, _ turn: DiarizedUtterance) -> TimeInterval {
        if t < turn.startTime { return turn.startTime - t }
        if t > turn.endTime { return t - turn.endTime }
        return 0
    }

    private static func overlaps(_ a: WordTimestamp, _ b: WordTimestamp) -> Bool {
        max(a.start, b.start) < min(a.end, b.end)
    }

    /// Positional (index-based) refinement for streaming, kept stable by design:
    /// the draft's word array — its count, per-word timings, and speaker-turn
    /// assignment — is the fixed scaffold; we only swap each word's *text* to the
    /// matching Whisper word (by position) and flip it refined (white). Words past
    /// Whisper's progress stay draft (blue). No words are added/removed and no word
    /// changes turn, so the layout doesn't reflow. Locked (user-edited) words keep
    /// their text but still consume a position.
    ///
    /// Alignment drifts where draft and Whisper word counts diverge; that's fine for
    /// a live preview — the completion re-merge replaces this with the exact result.
    /// `from` is the global word index already refined on a previous call: turns whose
    /// words all fall before it are returned untouched (cheap on long files), so each
    /// tick only rebuilds the turns at the growing edge instead of the whole transcript.
    static func replacePositional(turns: [DiarizedUtterance], whisperWords: [String], from: Int = 0) -> [DiarizedUtterance] {
        guard !whisperWords.isEmpty else { return turns }
        var idx = 0
        return turns.map { turn in
            let count = turn.words?.count ?? 0
            let turnStart = idx
            idx += count
            // Already fully refined on an earlier tick → leave as-is (no work, COW share).
            if turnStart + count <= from { return turn }
            guard var words = turn.words, !words.isEmpty else { return turn }
            for w in words.indices {
                let g = turnStart + w
                if words[w].isLocked { continue }
                if g < whisperWords.count {
                    words[w].word = whisperWords[g]
                    words[w].refined = true
                } else {
                    words[w].refined = false
                }
            }
            var t = turn
            t.words = words
            t.text = words.map(\.word).joined(separator: " ")
            return t
        }
    }

    /// Even-distributes a completed Whisper window's accurate text across its
    /// `[start, end]` span into refined pseudo-words. Used during streaming where the
    /// text is accurate but per-word timing isn't available yet (timing becomes exact
    /// in the final pass). These feed `refine(...)` exactly like real Whisper words.
    static func pseudoWords(text: String, start: TimeInterval, end: TimeInterval) -> [WordTimestamp] {
        let tokens = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        guard !tokens.isEmpty else { return [] }
        let span = max(0, end - start)
        let step = span / Double(tokens.count)
        return tokens.enumerated().map { i, tok in
            WordTimestamp(
                word: tok,
                start: start + step * Double(i),
                end: start + step * Double(i + 1),
                confidence: 1.0,
                refined: true
            )
        }
    }
}
